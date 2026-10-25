require 'json'
require 'gollum/projectbook_creation'
require 'open3'

module Gollum
  module ProjectbookTree
    Error = ProjectbookCreation::Error
    def self.parent(path); value = ::File.dirname(path); value == '.' ? '' : value; end
    def self.order_path(folder); folder.empty? ? '.order' : folder + '/.order'; end
    def self.read_order(wiki, folder, revision = nil)
      revision ||= wiki.commit_for(wiki.ref)&.id
      return [] unless revision
      path = [wiki.page_file_dir.to_s, order_path(folder)].reject(&:empty?).join('/')
      out, _, status = Open3.capture3('git', '-C', wiki.path, 'show', "#{revision}:#{path}")
      return [] unless status.success?
      names = JSON.parse(out)
      names.is_a?(Array) ? names.select { |name| name.is_a?(String) && !name.include?('/') && !name.start_with?('.') }.uniq : []
    rescue JSON::ParserError
      []
    end
    def self.children(snapshot, folder)
      prefix = folder.empty? ? '' : folder + '/'
      snapshot.entries.filter_map do |entry|
        path = entry[:path]
        next unless path.start_with?(prefix)
        name, rest = path.delete_prefix(prefix).split('/', 2)
        next if !name || name.start_with?('.', '_')
        [name, !rest.nil?]
      end.uniq.sort_by { |name, directory| [directory ? 0 : 1, name.downcase] }.map(&:first).uniq
    end
    def self.ordered(wiki, snapshot, folder)
      children = children(snapshot, folder)
      order = read_order(wiki, folder, snapshot.revision)
      (order & children) + (children - order)
    end
    def self.write_order(wiki, committer, folder, names)
      path = order_path(folder)
      old = wiki.file(path)&.raw_data
      ProjectbookSave.disk_check!(wiki, path, old)
      prefix = wiki.page_file_dir.to_s
      full = prefix.empty? ? path : prefix + '/' + path
      committer.add(full, JSON.pretty_generate(names.uniq) + "\n")
      committer.after_commit { |index, _| index.update_working_dir(full) }
    end
    # Existing manual orders absorb new children at the end, in the same commit.
    # No .order is created by normal document creation.
    def self.append(wiki, committer, path)
      return unless wiki.commit_for(wiki.ref)
      return unless wiki.tree_map_for(wiki.commit_for(wiki.ref).id).any? { |entry| entry.name == '.order' }
      snapshot = ProjectbookKnowledge.new(wiki)
      parts = path.split('/')
      parts.each_index do |index|
        folder = parts.first(index).join('/')
        next unless snapshot.entries.any? { |e| e[:path] == order_path(folder) }
        names = ordered(wiki, snapshot, folder)
        name = parts[index]
        next if name.start_with?('.') || names.include?(name)
        write_order(wiki, committer, folder, names + [name])
      end
    end
    def self.move_file(wiki, snapshot, input, source, target, folder, options)
      entry = snapshot.entries.find { |e| e[:path] == source }
      raise Error.new('File no longer exists.', 404) unless entry
      raise Error.new('File changed. Reload and try again.', 412) unless input['etag'] == entry[:sha]
      ProjectbookSave.destination!(wiki, target, markdown: false)
      # Binary bytes are read locally, never sent through a JSON text response.
      content = wiki.file(source).raw_data
      ProjectbookSave.disk_check!(wiki, source, content)
      committer = Gollum::Committer.new(wiki, options.merge(message: "Move #{source} to #{target}"))
      append(wiki, committer, target)
      old_parent = parent(source)
      if snapshot.entries.any? { |e| e[:path] == order_path(old_parent) }
        write_order(wiki, committer, old_parent, ordered(wiki, snapshot, old_parent) - [::File.basename(source)])
      end
      wiki.write_file(target, content, committer: committer, normalize: false)
      wiki.delete_file(source, committer: committer)
      if !old_parent.empty? && children(snapshot, old_parent) == [::File.basename(source)] && !wiki.file(old_parent + '/.gitkeep')
        wiki.write_file(old_parent + '/.gitkeep', '', committer: committer, normalize: false)
      end
      {revision: committer.commit, path: target}
    end
    def self.apply(wiki, input, options)
      raise Error.new('Editing is disabled.', 403) unless wiki.allow_editing
      raise Error, 'Invalid tree operation.' unless input.is_a?(Hash)
      snapshot = ProjectbookKnowledge.new(wiki)
      raise Error.new('The book changed. Reload the tree and try again.', 412) unless input['revision'] == snapshot.revision
      raise Error.new('Save local Git changes before editing the tree.', 409) unless snapshot.git('status', '--porcelain').empty? && snapshot.git('rev-parse', 'HEAD').strip == snapshot.revision
      source = ProjectbookSave.path!(input['source'])
      source.split('/').each { |part| ProjectbookCreation.segment!(part) }
      folder = input['folder']
      raise Error, 'Invalid folder.' unless folder.is_a?(String)
      folder.split('/', -1).each { |part| ProjectbookCreation.segment!(part) } unless folder.empty?
      raise Error.new('Folder no longer exists.', 404) unless folder.empty? || snapshot.entries.any? { |e| e[:path].start_with?(folder + '/') }
      if input['action'] == 'reorder'
        raise Error, 'Reorder items within their current folder.' unless parent(source) == folder
        names = ordered(wiki, snapshot, folder)
        name = ::File.basename(source)
        raise Error.new('Item no longer exists.', 404) unless names.include?(name)
        before = input['before']
        raise Error, 'Invalid insertion point.' unless before.nil? || (before.is_a?(String) && names.include?(before) && before != name)
        result = names - [name]
        result.insert(before ? result.index(before) : result.length, name)
        return {revision: snapshot.revision, unchanged: true} if result == names
        committer = Gollum::Committer.new(wiki, options.merge(message: "Reorder #{folder.empty? ? 'book root' : folder}"))
        write_order(wiki, committer, folder, result)
        {revision: committer.commit, order: result}
      elsif input['action'] == 'move'
        target = [folder, ::File.basename(source)].reject(&:empty?).join('/')
        raise Error, 'Choose a different folder.' if target == source
        page = wiki.page(source)
        return move_file(wiki, snapshot, input, source, target, folder, options) unless page && page.url_path == source && page.format == :markdown
        result = ProjectbookSave.save(wiki, {'source_path'=>source, 'path'=>target, 'content'=>input['content'], 'etag'=>input['etag']}, [], options.merge(message: "Move #{source} to #{target}")) do |committer|
          old_parent = parent(source)
          if snapshot.entries.any? { |e| e[:path] == order_path(old_parent) }
            write_order(wiki, committer, old_parent, ordered(wiki, snapshot, old_parent) - [::File.basename(source)])
          end
          # Retain an empty source directory so it remains a drop target.
          if !old_parent.empty? && children(snapshot, old_parent) == [::File.basename(source)]
            wiki.write_file(old_parent + '/.gitkeep', '', committer: committer, normalize: false) unless wiki.file(old_parent + '/.gitkeep')
          end
        end
        {revision: result[:commit], path: target}
      else
        raise Error, 'Choose move or reorder.'
      end
    end
  end
end
