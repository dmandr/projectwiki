require 'open3'
require 'json'
require 'timeout'

module Gollum
  # Plan against an immutable revision, then add every move/link/order change to
  # the caller's committer. The HTTP write lock covers preview and apply requests.
  module ProjectbookMove
    Error = ProjectbookCreation::Error
    def self.map(path, source, target)
      path == source ? target : path.start_with?(source + '/') ? target + path.delete_prefix(source) : path
    end
    def self.clean!(snapshot, wiki)
      raise Error.new('The book changed. Refresh the move preview.', 412) unless wiki.commit_for(wiki.ref).id == snapshot.revision
      raise Error.new('Save local Git changes before moving files.', 409) unless snapshot.git('status', '--porcelain', '--untracked-files=all').empty? && snapshot.git('rev-parse', 'HEAD').strip == snapshot.revision
    end
    def self.prepare(wiki, source:, target:, revision:, content: nil, etag: nil, overrides: {})
      raise Error.new('Editing is disabled.', 403) unless wiki.allow_editing
      source = ProjectbookSave.path!(source); target = ProjectbookSave.path!(target)
      if ProjectbookFolders.page?(source)
        raise Error, 'Move the folder to another folder path, keeping .index.md.' unless ProjectbookFolders.page?(target)
        folder_page = wiki.page(source)
        raise Error.new('Folder page changed. Reload before moving.',412) if !folder_page || (etag && folder_page.sha != etag)
        overrides = overrides.merge(source=>content) if content
        content = nil
        source = ::File.dirname(source); target = ::File.dirname(target)
      end
      [source,target].each { |path| path.split('/').each_with_index { |part,i| ProjectbookCreation.segment!(part) unless ProjectbookFolders.page?(path) && i == path.split('/').length-1 } }
      raise Error, 'Choose a different destination outside the source folder.' if target == source || target.start_with?(source + '/')
      snapshot = ProjectbookKnowledge.new(wiki)
      raise Error.new('The book changed. Refresh the move preview.', 412) unless revision == snapshot.revision
      clean!(snapshot, wiki)
      moved = snapshot.entries.select { |e| e[:path] == source || e[:path].start_with?(source + '/') }
      raise Error.new('Source no longer exists.', 404) if moved.empty?
      folder = moved.none? { |e| e[:path] == source }
      # Never silently omit tracked symlinks/submodules from a directory move.
      raw = snapshot.git('ls-tree', '-rz', snapshot.revision).split("\0")
      raise Error, 'Folders containing symlinks or submodules cannot be moved.' if raw.any? { |record| header,path=record.split("\t",2); path && (path==source || path.start_with?(source+'/')) && !%w[100644 100755].include?(header.split.first) }
      ProjectbookSave.destination!(wiki, target, markdown: false)
      entry = moved.find { |e| e[:path] == source }
      raise Error.new('Document changed. Refresh the move preview.', 412) if etag && entry && etag != entry[:sha]
      if content
        raise Error, 'Only a single Markdown document accepts edited content.' unless entry && snapshot.markdown?(entry) && content.is_a?(String) && content.bytesize <= ProjectbookKnowledge::MAX_TEXT
      end
      documents = snapshot.entries.select { |e| snapshot.markdown?(e) }.map do |e|
        {path: e[:path], content: overrides.fetch(e[:path]) { e[:path] == source && content ? content : snapshot.text(e) }}
      end
      raise Error, 'The Markdown corpus exceeds the move scan limit (64 MiB).' if documents.sum { |d| d[:content].bytesize } > 64 * 1024 * 1024
      runner = ENV.fetch('PROJECTBOOK_LINK_REWRITER', '/experiment/editor/dist/book-links.cjs')
      begin
        output, error, status = Timeout.timeout(60) { Open3.capture3('node', runner, stdin_data: JSON.generate(source: source, target: target, paths: snapshot.entries.map { |e| e[:path] }, documents: documents)) }
        raise Error, 'Could not parse book links. Nothing was moved.' unless status.success?
        rewritten = JSON.parse(output).to_h { |d| [d.fetch('path'), d.fetch('content')] }
      rescue Timeout::Error, Errno::ENOENT, JSON::ParserError
        raise Error, 'Link preview is unavailable or timed out. Nothing was moved.'
      end
      writes = {}; deletes = moved.map { |e| e[:path] }
      moved.each do |e|
        path=e[:path]; bytes=wiki.file(path).raw_data
        ProjectbookSave.disk_check!(wiki,path,bytes)
        writes[map(path,source,target)] = rewritten.fetch(path, bytes)
      end
      documents.each do |doc|
        path=doc[:path]; next if deletes.include?(path)
        text=rewritten.fetch(path)
        if ProjectbookTasks.identity(path)
          data=ProjectbookTasks.parse(text,path)
          if data['source_path'] && map(data['source_path'],source,target) != data['source_path']
            data['source_path']=map(data['source_path'],source,target)
            text=ProjectbookTasks.serialize(data)
          end
        end
        original=snapshot.text(snapshot.entries.find { |e| e[:path]==path })
        writes[path]=text if text != original
      end
      old_parent=ProjectbookTree.parent(source); new_parent=ProjectbookTree.parent(target)
      [old_parent,new_parent].uniq.each do |parent|
        path=ProjectbookTree.order_path(parent)
        next unless snapshot.entries.any? { |e| e[:path]==path }
        names=ProjectbookTree.ordered(wiki,snapshot,parent)
        if old_parent == new_parent
          names=names.map { |name| name==::File.basename(source) ? ::File.basename(target) : name }
        else
          names -= [::File.basename(source)] if parent==old_parent
          names << ::File.basename(target) if parent==new_parent
        end
        writes[path]=JSON.pretty_generate(names.uniq)+"\n"
      end
      # Add missing ancestors to existing manual orders (editor can create paths).
      parts=target.split('/')
      parts.each_index do |i|
        parent=parts.first(i).join('/'); path=ProjectbookTree.order_path(parent)
        next if writes.key?(path) || !snapshot.entries.any? { |e| e[:path]==path }
        names=ProjectbookTree.ordered(wiki,snapshot,parent)
        writes[path]=JSON.pretty_generate(names+[parts[i]])+"\n" unless names.include?(parts[i])
      end
      if !old_parent.empty? && ProjectbookTree.children(snapshot,old_parent)==[::File.basename(source)] && !wiki.file(old_parent+'/.gitkeep')
        writes[old_parent+'/.gitkeep']=''
      end
      writes.each do |path, bytes|
        old=wiki.file(path)&.raw_data
        ProjectbookSave.disk_check!(wiki,path,old)
      end
      clean!(snapshot, wiki)
      {snapshot: snapshot, source: source, target: target, folder: folder, writes: writes, deletes: deletes, moved: moved}
    end
    def self.preview(plan)
      snapshot=plan[:snapshot]; total=0
      changes=plan[:writes].map do |path,content|
        previous=plan[:moved].find { |e| map(e[:path],plan[:source],plan[:target])==path }
        old_path=previous ? previous[:path] : path
        entry=snapshot.entries.find { |e| e[:path]==old_path }
        item={path: path, previous_path: old_path, expected_version: entry && entry[:sha], moved: old_path!=path}
        if path.match?(/\.(md|markdown)\z/i) && total < 100_000
          diff=snapshot.document_diff(entry ? snapshot.text(entry) : '',content,path)
          total+=diff[:diff].length; item.merge!(diff)
        end
        item
      end
      {revision: snapshot.revision, path: plan[:target], folder: plan[:folder], moved_count: plan[:moved].size,
       updated_count: changes.count { |c| !c[:moved] }, changes: changes, diff_limit: 100_000}
    end
    def self.add(wiki, committer, plan)
      clean!(plan[:snapshot],wiki)
      plan[:deletes].each { |path| wiki.delete_file(path,committer:committer) }
      plan[:writes].each do |path,content|
        committer.add(path,content)
        committer.after_commit { |index,_| index.update_working_dir(path) }
      end
    end
    def self.apply(wiki, plan, options)
      committer=Gollum::Committer.new(wiki,options.merge(message:"Move #{plan[:source]} to #{plan[:target]} and update links"))
      add(wiki,committer,plan)
      {revision:committer.commit,path:plan[:target],folder:plan[:folder]}
    end
  end
end
