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

    def self.save(wiki, input, uploads, options)
      raise Error, 'Invalid save request.' unless input.is_a?(Hash)
      target = path!(input['path'])
      content = input['content']
      raise Error, 'Invalid Markdown content.' unless content.is_a?(String) && content.bytesize <= 2 * 1024 * 1024
      page = wiki.page(target)
      if input['create'] == true
        parent = ::File.dirname(target); parent = '' if parent == '.'
        target = ProjectbookCreation.prepare(wiki, 'document', parent, ::File.basename(target))
      else
        raise Error.new('The document was moved or deleted. Your draft is preserved.', 409) unless page && page.url_path == target
        raise Error.new('This document has changed. Your draft is preserved; compare with the latest version before saving.', 412) unless input['etag'] == page.sha
        raise Error, 'Only Markdown documents are supported here.' unless page.format == :markdown
        disk_check!(wiki, target, page.text_data)
      end
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
      return {path: target, commit: wiki.commit_for(wiki.ref).id} if page && page.text_data == content && prepared.empty? && input['create'] != true
      committer = Gollum::Committer.new(wiki, options)
      commit = {committer: committer, normalize: false}
      if input['create'] == true
        wiki.write_file(target, content, commit)
      else
        # Exact bytes from Markdown mode; opening and saving does not reformat it.
        committer.add(page.path, content)
        committer.after_commit { |index, _| index.update_working_dir(page.path) }
      end
      prepared.each { |path, temp| wiki.write_file(path, ::File.binread(temp.path), commit) }
      {path: target, commit: committer.commit}
    end
  end
end
