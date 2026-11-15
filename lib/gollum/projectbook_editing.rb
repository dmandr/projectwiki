require 'json'
require 'rack/request'
require 'fileutils'
require 'securerandom'

module Gollum
  # A shared, atomic lease fence: no new editor can enter after draining starts.
  module ProjectbookEditing
    class Endpoint
      PATH = '/gollum/projectbook/editing'
      def initialize(app); @app = app; end
      def call(env)
        return @app.call(env) unless env['PATH_INFO'] == PATH
        request = Rack::Request.new(env)
        return reply(405, error: 'POST required') unless request.post?
        token = ENV.fetch('PROJECTBOOK_MCP_TOKEN', '')
        internal = !token.empty? && Rack::Utils.secure_compare(env['HTTP_AUTHORIZATION'].to_s, "Bearer #{token}")
        unless internal
          return reply(403, error: 'Use the editor') unless env['HTTP_X_PROJECTWIKI_REQUEST'] == '1'
          return reply(403, error: 'Cross-origin request') if request.env['HTTP_ORIGIN'] && request.env['HTTP_ORIGIN'] != "#{request.scheme}://#{request.host_with_port}"
        end
        data = JSON.parse(request.body.read(2049))
        return reply(422, error: 'Invalid request') unless data.is_a?(Hash)
        action = data['action']
        return reply(403, error: 'Manager authorization required') if %w[prepare resume status].include?(action) && !internal
        path = ENV.fetch('PROJECTBOOK_SETTINGS_FILE', '/var/lib/projectbook/settings.json') + '.editors'
        FileUtils.mkdir_p(::File.dirname(path))
        ::File.open(path, ::File::RDWR | ::File::CREAT, 0600) do |file|
          file.flock(::File::LOCK_EX)
          raw = file.read
          state = JSON.parse(raw.empty? ? '{}' : raw)
          now = Time.now.to_f
          sessions = (state['sessions'] ||= {})
          sessions.delete_if { |_, deadline| deadline < now }
          state.delete('drain') if state.fetch('drain', 0) < now
          case action
          when 'heartbeat', 'close'
            id = data['session'].to_s
            return reply(422, error: 'Invalid editor session') unless id.match?(/\A[a-f0-9-]{36}\z/)
            if action == 'close'
              sessions.delete(id)
            elsif state['drain']
              return reply(409, error: 'Book is updating. Your draft is kept; please wait.')
            else
              sessions[id] = now + 180
            end
          when 'prepare'
            return reply(409, active_editors: sessions.size, error: 'Waiting for open editors to close') unless sessions.empty?
            state['drain'] = now + 1800
          when 'resume'
            state.delete('drain')
          when 'status'
          else
            return reply(422, error: 'Unknown action')
          end
          file.rewind; file.write(JSON.generate(state)); file.truncate(file.pos); file.flush; file.fsync
          reply(200, active_editors: sessions.size, draining: !!state['drain'])
        end
      rescue JSON::ParserError
        reply(422, error: 'Invalid editor state')
      end
      def reply(code, data)
        [code, {'content-type' => 'application/json', 'cache-control' => 'no-store'}, [JSON.generate(data)]]
      end
    end
  end
end
