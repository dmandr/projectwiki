require 'json'
require 'date'
require 'digest'
require 'uri'
require 'kramdown'
require 'kramdown-parser-gfm'

module Gollum
  # Portable task/list Markdown files. The title and JSON metadata in each file
  # are authoritative; link labels are readable fallbacks, never duplicate data.
  module ProjectbookTasks
    Error = ProjectbookCreation::Error
    UUID = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/
    def self.path(kind, id)
      raise Error, 'Use a UUID for the task or list ID.' unless id.is_a?(String) && UUID.match?(id)
      raise Error, 'Choose task or list.' unless %w[task list].include?(kind)
      ".projectbook/#{kind == 'task' ? 'tasks' : 'task-lists'}/#{id}.md"
    end

    def self.identity(path)
      match = %r{\A(Tasks|TaskLists|\.projectbook/tasks|\.projectbook/task-lists)/([0-9a-f-]+)\.md\z}.match(path)
      match && UUID.match?(match[2]) ? [%w[Tasks .projectbook/tasks].include?(match[1]) ? 'task' : 'list', match[2]] : nil
    end

    def self.legacy_path(kind, id)
      path(kind, id) # Validate before constructing a compatibility path.
      "#{kind == 'task' ? 'Tasks' : 'TaskLists'}/#{id}.md"
    end

    def self.normalize(data)
      raise Error, 'Invalid TODO metadata.' unless data.is_a?(Hash)
      kind, id = data.values_at('kind', 'id')
      path(kind, id)
      title = data['title']
      raise Error, 'TODO title must be 1..200 characters on one line.' unless title.is_a?(String) && (1..200).cover?(title.strip.length) && !title.match?(/[\x00-\x1f\x7f]/)
      notes = data.fetch('notes', '')
      raise Error, 'TODO notes must be text, at most 20000 characters.' unless notes.is_a?(String) && notes.length <= 20_000
      result = {'kind' => kind, 'id' => id, 'title' => title.strip, 'notes' => notes}
      if kind == 'task'
        raise Error, 'Select one TODO list.' unless data['list_id'].is_a?(String) && UUID.match?(data['list_id'])
        raise Error, 'Choose open or done.' unless %w[open done].include?(data['status'])
        due = data.fetch('due', '')
        raise Error, 'Use YYYY-MM-DD for the due date.' unless due.is_a?(String) && (due.empty? || due.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(due))
        result.merge!('list_id' => data['list_id'], 'status' => data['status'], 'due' => due)
        if data.key?('source_path') && data['source_path'] != ''
          source = ProjectbookSave.path!(data['source_path'])
          raise Error, 'Task source must be a Markdown document.' unless source.match?(/\.(md|markdown)\z/i)
          result['source_path'] = source
        end
      end
      result
    rescue Date::Error
      raise Error, 'Invalid due date.'
    end

    def self.serialize(data)
      data = normalize(data)
      metadata = data.reject { |k, _| %w[title notes].include?(k) }.merge('schema' => 1)
      ProjectbookTitles.markdown_heading(data['title']) + "\n```projectbook-todo\n#{JSON.pretty_generate(metadata)}\n```\n\n#{data['notes']}"
    end

    def self.parse(content, target)
      kind, id = identity(target)
      raise Error, 'Not a TODO file.' unless kind
      match = /\A\# ([^\n]+)\n+```projectbook-todo\n(.*?)\n```\n?(?:\n)?(.*)\z/m.match(content)
      raise Error, 'Invalid TODO file. Keep the title and projectbook-todo metadata block.' unless match
      metadata = JSON.parse(match[2])
      raise Error, 'TODO ID/kind/schema does not match its path.' unless metadata.is_a?(Hash) && metadata['kind'] == kind && metadata['id'] == id && metadata['schema'] == 1
      normalize(metadata.merge('title' => ProjectbookTitles.title("# #{match[1]}\n", target), 'notes' => match[3]))
    rescue JSON::ParserError
      raise Error, 'Invalid TODO JSON metadata.'
    end

    def self.catalog(snapshot, sources: false)
      result = {revision: snapshot.revision, tasks: [], lists: [], errors: []}
      snapshot.entries.each do |entry|
        ident = identity(entry[:path])
        next if ident && entry[:path] != path(*ident) && snapshot.entries.any? { |other| other[:path] == path(*ident) }
        next unless identity(entry[:path])
        begin
          item = parse(snapshot.text(entry), entry[:path]).merge('path' => entry[:path], 'version' => entry[:sha])
          result[item['kind'] == 'task' ? :tasks : :lists] << item
        rescue Error => e
          result[:errors] << {path: entry[:path], error: e.message}
        end
      end
      if sources
        refs = source_references(snapshot)
        result[:tasks].each do |item|
          candidates = refs.fetch(item['id'], [])
          recorded = item['source_path']
          # Never guess between several references or follow a stale origin to a
          # document which no longer contains the task.
          item['source_target'] = candidates.include?(recorded) ? recorded : candidates.one? ? candidates.first : item['path']
          item['source_references'] = candidates
        end
      end
      result[:lists].sort_by! { |item| item['title'].downcase }
      result[:tasks].sort_by! { |item| [item['status'] == 'done' ? 1 : 0, item['due'].empty? ? '9999' : item['due'], item['title'].downcase] }
      result
    end

    # Derive backlinks from actual Markdown links, not code blocks or mentions
    # of UUIDs. The immutable snapshot also keeps history navigation consistent.
    def self.source_references(snapshot)
      refs = Hash.new { |hash, key| hash[key] = [] }
      snapshot.docs.each do |entry|
        next if identity(entry[:path]) || entry[:bytes] > ProjectbookKnowledge::MAX_TEXT
        content = snapshot.text(entry)
        next unless content.include?('TODO:')
        walk = lambda do |node|
          if node.type == :a
            text = lambda { |n| n.type == :text ? n.value.to_s : n.children.map { |child| text.call(child) }.join }
            if text.call(node).start_with?('TODO:')
              begin
                url = URI.join('https://book.invalid/' + NavigationIndex.encode_path(entry[:path]), URI::DEFAULT_PARSER.escape(node.attr['href'].to_s))
                target = URI::DEFAULT_PARSER.unescape(url.path).delete_prefix('/')
                target += '.md' unless target.end_with?('.md')
                ident = identity(target)
                if url.scheme == 'https' && url.host == 'book.invalid' && ident && ident[0] == 'task'
                  refs[ident[1]] << entry[:path] unless refs[ident[1]].include?(entry[:path])
                end
              rescue URI::Error
                # An invalid ordinary link is not a TODO definition.
              end
            end
          end
          node.children.each { |child| walk.call(child) }
        end
        walk.call(Kramdown::Document.new(content, input: 'GFM').root)
      end
      refs
    end

    # Validate every file first, then add to the caller's single Git commit.
    def self.prepare(wiki, changes)
      raise Error, 'Use at most 100 TODO changes per save.' unless changes.is_a?(Array) && changes.length <= 100
      return [] if changes.empty?
      catalog = catalog(ProjectbookKnowledge.new(wiki))
      existing = (catalog[:tasks] + catalog[:lists]).to_h { |item| [item['path'], item] }
      seen = []
      prepared = changes.map do |change|
        raise Error, 'Invalid TODO change.' unless change.is_a?(Hash)
        data = normalize(change)
        target = path(data['kind'], data['id'])
        raise Error, 'Duplicate TODO change.' if seen.include?(target)
        seen << target
        page = wiki.page(target)
        version = change['expected_version']
        raise Error, 'expected_version is required (empty for a new TODO).' unless version.is_a?(String) && /\A(?:[0-9a-f]{40})?\z/.match?(version)
        raise Error.new('TODO changed or already exists. Reload it and reconcile your draft.', 412) unless version == (page && page.url_path == target ? page.sha : '')
        content = serialize(data)
        if page
          raise Error, 'This path is not a valid TODO file.' unless existing[target]
          ProjectbookSave.disk_check!(wiki, target, page.text_data)
        else
          ProjectbookSave.destination!(wiki, target, system_task: true)
        end
        existing[target] = data
        {path: target, content: content, previous_content: page&.text_data, page: page, data: data}
      end
      names = {}
      existing.values.select { |item| item['kind'] == 'list' }.each do |item|
        name = item['title'].downcase
        raise Error.new('A TODO list with this name already exists. Select it instead.', 409) if names[name] && names[name] != item['id']
        names[name] = item['id']
      end
      prepared.each do |item|
        data = item[:data]
        if data['kind'] == 'task' && !existing.key?(path('list', data['list_id']))
          raise Error, 'The selected TODO list does not exist.'
        end
      end
      prepared.reject { |item| item[:content] == item[:previous_content] }
    end

    def self.add(wiki, committer, prepared)
      prepared.each do |item|
        if item[:page]
          committer.add(item[:page].path, item[:content])
          committer.after_commit { |index, _| index.update_working_dir(item[:page].path) }
        else
          wiki.write_file(item[:path], item[:content], committer: committer, normalize: false)
        end
      end
    end

    def self.save(wiki, changes, options, dry_run: false)
      raise Error.new('Editing is disabled.', 403) unless wiki.allow_editing
      prepared = prepare(wiki, changes)
      result = {dry_run: dry_run, unchanged: prepared.empty?, changes: prepared.map { |item| item.slice(:path, :content, :previous_content) }}
      return result if dry_run || prepared.empty?
      committer = Gollum::Committer.new(wiki, options)
      add(wiki, committer, prepared)
      result.merge(commit: committer.commit)
    end
  end
end
