require 'jwt'
require 'json'
require 'net/http'
require 'uri'
require 'thread'

module Gollum
  # Access authenticates the client at the edge. Verify its signed origin assertion,
  # never the opaque OAuth token or the unverified email forwarding header.
  class ProjectbookAccess
    CACHE_SECONDS = 300
    REFRESH_SECONDS = 30
    MAX_JWKS_BYTES = 256 * 1024
    MAX_ASSERTION_BYTES = 16 * 1024

    def initialize
      @mutex = Mutex.new
      @keys = {}
      @issuer = nil
      @loaded_at = @attempted_at = -Float::INFINITY
    end

    def enabled?
      ENV['PROJECTBOOK_MCP_ACCESS_ENABLED'] == 'true'
    end

    def authorized?(env)
      return false unless enabled?
      issuer = ENV.fetch('PROJECTBOOK_MCP_ACCESS_ISSUER', '').strip
      audience = ENV.fetch('PROJECTBOOK_MCP_ACCESS_AUDIENCE', '').strip
      return false unless issuer.match?(%r{\Ahttps://[a-z0-9-]+\.cloudflareaccess\.com\z}) && !audience.empty?
      assertion = env['HTTP_CF_ACCESS_JWT_ASSERTION']
      return false unless assertion.is_a?(String) && assertion.bytesize.between?(1, MAX_ASSERTION_BYTES)

      claims, = JWT.decode(assertion, nil, true,
        algorithms: ['RS256'], iss: issuer, verify_iss: true,
        aud: audience, verify_aud: true, verify_iat: true,
        required_claims: %w[iss aud exp iat sub email]) do |header, payload|
        # Structural checks only: malformed claim types can otherwise raise inside
        # the JWT library. Identity is trusted only after signature/claim verification.
        raise JWT::DecodeError, 'Invalid claim types' unless valid_claim_types?(payload)
        kid = header['kid']
        raise JWT::DecodeError, 'Invalid signing key identifier' unless header['alg'] == 'RS256' && kid.is_a?(String) && kid.bytesize.between?(1, 256)
        signing_key(issuer, kid) || raise(JWT::DecodeError, 'Unknown signing key')
      end
      email = claims['email']
      # Access policy is the source of user authorization; do not duplicate its allowlist.
      email.is_a?(String) && !email.strip.empty?
    rescue JWT::DecodeError, JWT::JWKError, ArgumentError, KeyError, TypeError,
           JSON::ParserError, OpenSSL::OpenSSLError, IOError, SystemCallError,
           Timeout::Error, SocketError, URI::InvalidURIError, Net::ProtocolError
      # Never expose assertions, credentials, claims or network exception text.
      false
    end

    private

    def valid_claim_types?(claims)
      claims.is_a?(Hash) &&
        %w[exp iat].all? { |key| claims[key].is_a?(Numeric) } &&
        (!claims.key?('nbf') || claims['nbf'].is_a?(Numeric)) &&
        claims['iss'].is_a?(String) && claims['email'].is_a?(String) &&
        claims['sub'].is_a?(String) && !claims['sub'].empty? &&
        (claims['aud'].is_a?(String) || (claims['aud'].is_a?(Array) && claims['aud'].all? { |aud| aud.is_a?(String) }))
    end

    def signing_key(issuer, kid)
      @mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @issuer != issuer
          @issuer, @keys = issuer, {}
          @loaded_at = @attempted_at = -Float::INFINITY
        end
        fresh = now - @loaded_at < CACHE_SECONDS
        return @keys[kid] if fresh && @keys.key?(kid)
        # Bound refreshes for unknown key IDs and outages; expired keys fail closed.
        return nil if now - @attempted_at < REFRESH_SECONDS
        @attempted_at = now
        @keys = fetch_keys(issuer)
        @loaded_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @keys[kid]
      end
    end

    def fetch_keys(issuer)
      uri = URI(issuer + '/cdn-cgi/access/certs')
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = http.read_timeout = http.write_timeout = 3
      body = +''
      http.start do |connection|
        connection.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
          raise IOError, 'Access keys unavailable' unless response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            body << chunk
            raise IOError, 'Access keys exceed limit' if body.bytesize > MAX_JWKS_BYTES
          end
        end
      end
      keys = JSON.parse(body).fetch('keys')
      raise ArgumentError, 'Invalid Access keys' unless keys.is_a?(Array) && keys.length.between?(1, 20)
      keys.each_with_object({}) do |key, result|
        next unless key.is_a?(Hash) && key['kty'] == 'RSA' && key['alg'] == 'RS256' && key['use'] == 'sig'
        kid = key['kid']
        next unless kid.is_a?(String) && kid.bytesize.between?(1, 256)
        public_key = JWT::JWK.import(key).verify_key
        next unless public_key.is_a?(OpenSSL::PKey::RSA) && public_key.n.num_bits >= 2048
        result[kid] = public_key
      end
    end
  end
end
