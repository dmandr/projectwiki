require 'json'
require 'net/http'
require 'rack/request'
require 'digest'
require 'fileutils'

module Gollum
  module ProjectbookSettings
    class Endpoint
      PATH = '/gollum/projectbook/settings'
      def initialize(app); @app = app; end
      def call(env)
        return @app.call(env) unless [PATH, PATH + '/index', PATH + '/navigation'].include?(env['PATH_INFO'])
        request = Rack::Request.new(env)
        allowed = ['localhost', '127.0.0.1', '[::1]', URI(ENV.fetch('PROJECTBOOK_PUBLIC_URL', 'http://127.0.0.1')).host]
        return reply(403, error: 'Untrusted host.') unless allowed.include?(request.host)
        admin = ENV['PROJECTBOOK_SETTINGS_ADMIN'] == 'true'
        base = ENV.fetch('PROJECTBOOK_RAG_URL', '')
        if request.get? && request.path == PATH + '/navigation'
          return reply(200, navigation.merge(editable: admin))
        end
        if request.get? && request.path == PATH
          return reply(200, available: false, editable: false, message: 'Semantic search is not installed in this deployment. Enable PROJECTBOOK_RAG_AVAILABLE in deployment settings and restart.') if base.empty?
          code, data = backend(base, '/settings')
          return reply(code, data.merge('available' => true, 'editable' => admin))
        end
        return reply(405, error: 'Method not allowed.') unless request.post?
        return reply(403, error: 'Deployment settings are read-only.') unless admin
        return reply(403, error: 'Use the settings interface.') unless env['HTTP_X_PROJECTWIKI_REQUEST'] == '1'
        origin = env['HTTP_ORIGIN']
        return reply(403, error: 'Cross-origin request rejected.') if origin && origin != "#{request.scheme}://#{request.host_with_port}"
        return reply(415, error: 'Expected JSON.') unless request.media_type == 'application/json'
        payload = JSON.parse(request.body.read(8193))
        return reply(422, error: 'Invalid settings request.') unless payload.is_a?(Hash) && JSON.generate(payload).bytesize <= 8192
        if request.path == PATH + '/navigation'
          current = navigation
          return reply(409, error: 'Settings changed. Reload before saving.') unless payload['version'] == current[:version]
          return reply(422, error: 'Expected a confirmation setting.') unless [true, false].include?(payload['confirm_move'])
          file = navigation_file
          FileUtils.mkdir_p(::File.dirname(file))
          temp = file + '.tmp'
          ::File.write(temp, JSON.generate(confirm_move: payload['confirm_move']))
          ::File.rename(temp, file)
          return reply(200, navigation.merge(editable: admin))
        end
        return reply(503, error: 'Semantic search is not installed.') if base.empty?
        code, data = backend(base, request.path.end_with?('/index') ? '/index' : '/settings', payload)
        reply(code, data.merge('available' => true, 'editable' => admin))
      rescue JSON::ParserError
        reply(422, error: 'Invalid JSON.')
      rescue IOError, SystemCallError, Timeout::Error
        reply(503, available: true, editable: false, error: 'Search service is unavailable. Check deployment status; existing settings have not been changed.')
      end

      def navigation_file
        ENV.fetch('PROJECTBOOK_SETTINGS_FILE', '/var/lib/projectbook/settings.json')
      end
      def navigation
        raw = ::File.exist?(navigation_file) ? ::File.read(navigation_file) : '{}'
        data = JSON.parse(raw)
        {confirm_move: data.fetch('confirm_move', true), version: Digest::SHA256.hexdigest(raw)}
      end

      def backend(base, path, payload = nil)
        uri = URI(base + path)
        req = payload ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
        if payload
          req['Content-Type'] = 'application/json'
          req.body = JSON.generate(payload)
        end
        response = Net::HTTP.start(uri.hostname, uri.port, nil, nil, open_timeout: 2, read_timeout: 5) { |http| http.request(req) }
        [response.code.to_i, JSON.parse(response.body)]
      end

      def reply(status, payload)
        [status, {'content-type' => 'application/json', 'cache-control' => 'no-store'}, [JSON.generate(payload)]]
      end
    end
  end
end
