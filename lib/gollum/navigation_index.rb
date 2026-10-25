require 'cgi'
require 'thread'
require 'gollum/projectbook_titles'
require 'gollum/projectbook_folders'

module Gollum
  # Navigation needs names, not Page/File objects (which can load large blobs).
  # The local branch tip is checked per request; no network operation is involved.
  module NavigationIndex
    Entry = Struct.new(:path, :url_path, :title, :sha, keyword_init: true) do
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

      # An ordinary editable Markdown page doubles as a folder's landing page.
      def folder_page(path)
        entries.find { |entry| entry.url_path == "#{path}/.index.md" }
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
          previous = cached ? cached.entries.to_h { |item| [item.url_path, item] } : {}
          entries = revision ? wiki.tree_map_for(revision).filter_map do |entry|
            next if entry.path.split('/').any? { |part| part.start_with?('.') && part != '.gitkeep' } && !Gollum::ProjectbookFolders.page?(entry.path)
            next unless Gollum::Page.valid_page_name?(entry.name) ||
              (!entry.name.start_with?('_') && !Gollum::Page.protected_files.include?(entry.name))
            path = entry.path.dup.freeze
            url = prefix.empty? ? path : path.delete_prefix(prefix + '/')
            title = if previous[url]&.sha == entry.sha
              previous[url].title
            elsif Gollum::Page.format_for(url) == :markdown
              page = wiki.page(url)
              page ? ProjectbookTitles.title(page.text_data, url) : ProjectbookTitles.from_path(url)
            else
              ::File.basename(url)
            end
            Entry.new(path: path, url_path: url.freeze, title: title.freeze, sha: entry.sha).freeze
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
