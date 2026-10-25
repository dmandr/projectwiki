require 'thread'

module Gollum
  module ProjectbookCreation
    class Error < StandardError
      attr_reader :status
      def initialize(message, status = 422)
        @status = status
        super(message)
      end
    end

    # One writer at a time for this app process, including stock Gollum saves/uploads.
    # External Git clients and other instances still require future synchronization.
    class WriteLock
      LOCK = Mutex.new
      def initialize(app); @app = app; end
      def call(env)
        return @app.call(env) if %w[GET HEAD OPTIONS].include?(env['REQUEST_METHOD']) && !env['PATH_INFO'].to_s.start_with?('/gollum/projectbook/raw-notes')
        LOCK.synchronize { @app.call(env) }
      end
    end

    def self.segment!(value)
      unless value.is_a?(String) && !value.empty? && value == value.strip && value.bytesize <= 180 &&
          !value.match?(/[\\\/:\x00-\x1f\x7f%?#]/) && !value.start_with?('.', '_') &&
          !value.end_with?('.') && !Gollum::Page.protected_files.include?(value)
        raise Error, 'Use a name without slashes, reserved characters, or a leading dot/underscore.'
      end
      value
    end

    def self.prepare(wiki, kind, parent, name)
      raise Error, 'Choose document or folder.' unless %w[document folder].include?(kind)
      raise Error, 'Invalid folder path.' unless parent.is_a?(String)
      parts = parent.empty? ? [] : parent.split('/', -1)
      parts.each { |part| segment!(part) }
      segment!(name)
      name += '.md' if kind == 'document' && !name.end_with?('.md')
      target = (parts + [name]).join('/')
      revision = wiki.commit_for(wiki.ref)&.id
      prefix = wiki.page_file_dir.to_s.sub(%r{/+\z}, '')
      paths = revision ? wiki.tree_map_for(revision).map { |entry| prefix.empty? ? entry.path : entry.path.delete_prefix(prefix + '/') } : []
      if !parent.empty? && !paths.any? { |p| p.start_with?(parent + '/') }
        raise Error.new('The selected folder no longer exists. Reload and choose another folder.', 404)
      end
      if paths.any? { |p| p == target || p.start_with?(target + '/') } || (kind == 'document' && wiki.page(target))
        raise Error.new('A file or folder with this name already exists.', 409)
      end
      # Never traverse symlinks or overwrite local, not-yet-committed files.
      disk = ::File.join(wiki.path, prefix)
      (parts + [name]).each_with_index do |part, index|
        disk = ::File.join(disk, part)
        raise Error, 'Symbolic links cannot be used as a creation path.' if ::File.symlink?(disk)
        if index == parts.length && ::File.exist?(disk)
          raise Error.new('This path already exists on disk.', 409)
        end
      end
      target
    end
  end
end
