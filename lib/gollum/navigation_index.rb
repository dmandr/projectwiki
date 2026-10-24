require 'cgi'
require 'thread'

module Gollum
  # Navigation needs names, not Page/File objects (which can load large blobs).
  # The local branch tip is checked per request; no network operation is involved.
  module NavigationIndex
    Entry = Struct.new(:path, :url_path, keyword_init: true) do
      def name
        ::File.basename(path)
      end
      alias filename name

      def escaped_url_path
        NavigationIndex.encode_path(url_path)
      end
    end

    class Snapshot
      attr_reader :revision, :entries
      def initialize(revision, entries)
        @revision, @entries = revision, entries.freeze
        @html, @lock = {}, Mutex.new
      end

      def tree_html(base_url)
        @lock.synchronize do
          @html.clear if @html.length >= 8 && !@html.key?(base_url)
          @html[base_url] ||= yield(entries).freeze
        end
      end
    end

    @cache, @lock = {}, Mutex.new

    def self.encode_path(path)
      path.split('/').map { |part| CGI.escape(part).gsub('+', '%20') }.join('/')
    end

    def self.for(wiki)
      revision = wiki.commit_for(wiki.ref)&.id
      key = [::File.expand_path(wiki.path), wiki.ref.to_s, wiki.page_file_dir.to_s]
      @lock.synchronize do
        cached = @cache.delete(key)
        snapshot = if cached && cached.revision == revision
          cached
        else
          prefix = wiki.page_file_dir.to_s.sub(%r{/+\z}, '')
          entries = revision ? wiki.tree_map_for(revision).filter_map do |entry|
            next unless Gollum::Page.valid_page_name?(entry.name) ||
              (!entry.name.start_with?('_') && !Gollum::Page.protected_files.include?(entry.name))
            path = entry.path.dup.freeze
            url = prefix.empty? ? path : path.delete_prefix(prefix + '/')
            Entry.new(path: path, url_path: url.freeze).freeze
          end : []
          Snapshot.new(revision, entries)
        end
        @cache[key] = snapshot
        @cache.shift while @cache.length > 8
        snapshot
      end
    end
  end
end
