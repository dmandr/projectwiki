require 'pathname'

module Gollum
  module ProjectbookTaskMigration
    # Explicit startup migration: run before serving requests, never on page read.
    # Keep IDs and metadata intact; old Git revisions remain readable.
    def self.run(wiki)
      snapshot = ProjectbookKnowledge.new(wiki)
      legacy = snapshot.entries.select { |entry| (id = ProjectbookTasks.identity(entry[:path])) && entry[:path] != ProjectbookTasks.path(*id) }
      return {moved: 0, documents: 0} if legacy.empty?
      raise ProjectbookTasks::Error, 'TODO migration requires an editable book.' unless wiki.allow_editing
      unless snapshot.git('status', '--porcelain').empty? && snapshot.git('rev-parse', 'HEAD').strip == snapshot.revision
        raise ProjectbookTasks::Error, 'TODO migration requires a clean working tree on the configured book branch.'
      end
      moves = legacy.to_h { |entry| [entry[:path], ProjectbookTasks.path(*ProjectbookTasks.identity(entry[:path]))] }
      legacy.each do |entry|
        ProjectbookTasks.parse(snapshot.text(entry), entry[:path])
        ProjectbookSave.destination!(wiki, moves.fetch(entry[:path]), system_task: true)
      end
      documents = snapshot.entries.select { |entry| snapshot.markdown?(entry) }.filter_map do |entry|
        old = snapshot.text(entry)
        text = rewrite(old, entry[:path], moves.fetch(entry[:path], entry[:path]), moves)
        next if text == old && !moves.key?(entry[:path])
        [entry[:path], moves.fetch(entry[:path], entry[:path]), text]
      end
      committer = Gollum::Committer.new(wiki, name: 'ProjectBook', email: 'projectbook@local', message: 'Move TODO storage into .projectbook')
      documents.each do |old, target, text|
        if old != target
          wiki.write_file(target, text, committer: committer, normalize: false)
          wiki.delete_page(wiki.page(old), committer: committer)
        else
          page = wiki.page(old)
          raise ProjectbookTasks::Error, "Cannot migrate links in #{old}." unless page && page.url_path == old
          committer.add(page.path, text)
          committer.after_commit { |index, _| index.update_working_dir(page.path) }
        end
      end
      {moved: legacy.length, documents: documents.count { |old, target, _| old == target }, commit: committer.commit}
    end

    def self.rewrite(content, from, to, moves)
      fence = nil
      content.lines.map do |line|
        marker = /^ {0,3}(`{3,}|~{3,})/.match(line)
        if fence
          fence = nil if marker && marker[1][0] == fence[0] && marker[1].length >= fence.length
          next line
        elsif marker
          fence = marker[1]
          next line
        end
        # Preserve inline code and all bytes outside changed link destinations.
        line.split(/(`+.*?`+)/).each_with_index.map do |part, index|
          next part if index.odd?
          part.gsub(/(\]\(\s*<?)([^\s)>]+)|(\A {0,3}\[[^\]\n]+\]:\s*<?)([^\s>]+)/) do
            prefix, value = $1 ? [$1, $2] : [$3, $4]
            prefix + rewrite_url(value, from, to, moves)
          end
        end.join
      end.join
    end

    def self.rewrite_url(value, from, to, moves)
      return value if value.match?(%r{\A(?:[a-z][a-z\d+.-]*:|//|#|\?)}i)
      url = URI.join('https://book.invalid/' + NavigationIndex.encode_path(from), value)
      path = URI::DEFAULT_PARSER.unescape(url.path).delete_prefix('/')
      key = moves.key?(path) ? path : path + '.md'
      target = moves.fetch(key, path)
      return value if from == to && !moves.key?(key)
      encoded = NavigationIndex.encode_path(target)
      result = value.start_with?('/') ? '/' + encoded : Pathname.new(encoded).relative_path_from(Pathname.new(NavigationIndex.encode_path(::File.dirname(to)))).to_s
      result + (url.query ? '?' + url.query : '') + (url.fragment ? '#' + url.fragment : '')
    rescue URI::Error, ArgumentError
      value
    end
  end
end
