module Gollum
  # Validates the whole request before building a single Git commit. Attachments
  # are held by the browser until Save; no staging files are stored in the book.
  module ProjectbookSave
    Error = ProjectbookCreation::Error
    MAX_FILE = 20 * 1024 * 1024
    MAX_TOTAL = 50 * 1024 * 1024

    def self.path!(path)
      raise Error, 'Invalid document path.' unless path.is_a?(String) && path.bytesize <= 1024
      parts = path.split('/', -1)
      raise Error, 'Invalid document path.' if parts.empty? || parts.any? { |p| p.empty? || p.start_with?('.') || p.match?(/[\\\x00-\x1f\x7f]/) }
      raise Error, 'This file is reserved.' if Gollum::Page.protected_files.include?(parts.last)
      path
    end

    def self.disk_check!(wiki, path, expected = nil)
      disk = ::File.join(wiki.path, wiki.page_file_dir.to_s)
      path.split('/').each do |part|
        disk = ::File.join(disk, part)
        raise Error, 'Symbolic links cannot be used here.' if ::File.symlink?(disk)
      end
      if ::File.exist?(disk) && (!expected || !::File.file?(disk) || ::File.binread(disk) != expected.b)
        raise Error.new('There are local changes at this path. Save them before editing here.', 409)
      end
    end

    def self.destination!(wiki, target, system_task: false, markdown: true)
      parts = target.split('/')
      if system_task
        identity = ProjectbookTasks.identity(target)
        raise Error, 'Invalid system TODO path.' unless identity && target == ProjectbookTasks.path(*identity)
      else
        parts.each { |part| ProjectbookCreation.segment!(part) }
      end
      raise Error, 'Keep a Markdown file extension.' if markdown && Gollum::Page.format_for(target) != :markdown
      prefix = wiki.page_file_dir.to_s.sub(%r{/+\z}, '')
      revision = wiki.commit_for(wiki.ref)&.id
      paths = revision ? wiki.tree_map_for(revision).map { |entry| prefix.empty? ? entry.path : entry.path.delete_prefix(prefix + '/') } : []
      ancestors = (1...parts.length).map { |length| parts.first(length).join('/') }
      if paths.any? { |entry| entry.casecmp?(target) || entry.downcase.start_with?(target.downcase + '/') || ancestors.any? { |parent| entry.casecmp?(parent) } } || wiki.page(target)
        raise Error.new('A file or folder already occupies this path.', 409)
      end
      disk = ::File.join(wiki.path, prefix)
      parts.each_with_index do |part, index|
        if ::File.directory?(disk) && ::Dir.children(disk).any? { |entry| entry.casecmp?(part) && entry != part }
          raise Error.new('A path with different letter casing already exists.', 409)
        end
        disk = ::File.join(disk, part)
        raise Error, 'Symbolic links cannot be used here.' if ::File.symlink?(disk)
        if ::File.exist?(disk) && (index == parts.length - 1 || !::File.directory?(disk))
          raise Error.new('This path already exists on disk.', 409)
        end
      end
      target
    end

    def self.delete_document(wiki, input, options)
      raise Error.new('Editing is disabled.', 403) unless wiki.allow_editing
      raise Error, 'Invalid delete request.' unless input.is_a?(Hash)
      target = path!(input['path'])
      page = wiki.page(target)
      raise Error.new('The document was moved or deleted.', 404) unless page && page.url_path == target
      raise Error, 'Only Markdown documents can be deleted here.' unless page.format == :markdown
      raise Error.new('This document has changed. Reload and review it before deleting.', 412) unless input['etag'] == page.sha
      disk_check!(wiki, target, page.text_data)
      committer = Gollum::Committer.new(wiki, options.merge(message: "Delete #{target}"))
      wiki.delete_page(page, committer: committer)
      ProjectbookTree.remove(wiki,committer,target) if defined?(ProjectbookTree)
      {path: target, commit: committer.commit}
    end

    def self.save(wiki, input, uploads, options, dry_run: false)
      raise Error, 'Invalid save request.' unless input.is_a?(Hash)
      target = path!(input['path'])
      source = path!(input.fetch('source_path', target))
      content = input['content']
      raise Error, 'Invalid Markdown content.' unless content.is_a?(String) && content.bytesize <= 2 * 1024 * 1024
      content = ProjectbookTitles.ensure_title(content, source)
      page = wiki.page(source)
      if input['create'] == true
        destination!(wiki, target)
      else
        raise Error.new('The document was moved or deleted. Your draft is preserved.', 409) unless page && page.url_path == source
        raise Error.new('This document has changed. Your draft is preserved; compare with the latest version before saving.', 412) unless input['etag'] == page.sha
        raise Error, 'Only Markdown documents are supported here.' unless page.format == :markdown
        disk_check!(wiki, source, page.text_data)
        destination!(wiki, target) if target != source
      end
      todo_changes = input.fetch('todos', [])
      if todo_changes.is_a?(Array)
        todo_changes = todo_changes.map do |item|
          if item.is_a?(Hash) && item['kind'] == 'task' && item['expected_version'] == '' && !ProjectbookTasks.identity(target)
            item.merge('source_path' => target)
          else
            item
          end
        end
      end
      if ProjectbookTasks.identity(source) || ProjectbookTasks.identity(target)
        raise Error, 'TODO files have permanent paths. Change their title or list instead of moving them.' if source != target
        data = ProjectbookTasks.parse(content, target).merge('expected_version' => input['create'] == true ? '' : input['etag'])
        ProjectbookTasks.prepare(wiki, [data])
      end
      tasks = ProjectbookTasks.prepare(wiki, todo_changes)
      raise Error, 'The same TODO cannot be edited twice in one save.' if tasks.any? { |item| item[:path] == target }
      files = input.fetch('attachments', [])
      raise Error, 'Invalid attachments.' unless files.is_a?(Array) && files.length <= 30 && uploads.is_a?(Array) && files.length == uploads.length
      raise Error.new('File uploads are disabled.', 403) if !files.empty? && !wiki.allow_uploads
      seen = []; total = 0
      prepared = files.each_with_index.map do |item, i|
        raise Error, 'Invalid attachment.' unless item.is_a?(Hash)
        path = item['path']
        raise Error, 'Invalid attachment path.' unless path.is_a?(String) && path.match?(%r{\Auploads/[0-9a-f-]{36}/[^/]+\z})
        ProjectbookCreation.segment!(::File.basename(path))
        raise Error, 'Duplicate attachment.' if seen.include?(path)
        seen << path
        raise Error.new('An attachment already exists. Reattach it with a new name.', 409) if wiki.file(path)
        disk_check!(wiki, path)
        file = uploads[i]
        temp = file.is_a?(Hash) && (file[:tempfile] || file['tempfile'])
        raise Error, 'Missing attachment data.' unless temp.is_a?(Tempfile)
        total += temp.size
        raise Error.new('Attachments exceed the limit: 20 MB per file, 50 MB per save.', 413) if temp.size > MAX_FILE || total > MAX_TOTAL
        [path, temp]
      end
      moving = source != target && input['create'] != true
      move_plan = moving ? ProjectbookMove.prepare(wiki, source: source, target: target, revision: input['move_revision'], content: content, etag: input['etag'], overrides: tasks.to_h { |item| [item[:path],item[:content]] }) : nil
      unchanged = source == target && page && page.text_data == content && prepared.empty? && tasks.empty? && input['create'] != true
      if dry_run
        return {path: target, content: content, previous_content: input['create'] == true ? '' : page.text_data, unchanged: !!unchanged}
      end
      return {path: target, commit: wiki.commit_for(wiki.ref).id} if unchanged
      committer = Gollum::Committer.new(wiki, options)
      commit = {committer: committer, normalize: false}
      if move_plan
        # The shared move plan includes the edited document and incoming links.
      elsif input['create'] == true || source != target
        wiki.write_file(target, content, commit)
        if input['create'] != true
          wiki.delete_page(page, commit)
        end
      else
        # Exact bytes from Markdown mode; opening and saving does not reformat it.
        committer.add(page.path, content)
        committer.after_commit { |index, _| index.update_working_dir(page.path) }
      end
      prepared.each { |path, temp| wiki.write_file(path, ::File.binread(temp.path), commit) }
      ProjectbookTasks.add(wiki, committer, tasks)
      ProjectbookMove.add(wiki,committer,move_plan) if move_plan
      ProjectbookTree.append(wiki, committer, target) if defined?(ProjectbookTree) && input['create'] == true
      yield(committer) if block_given?
      {path: target, commit: committer.commit}
    end
  end
end
