require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV'] = 'test'
require 'gollum/app'

class ProjectbookAccessTest < Minitest::Test
  ISSUER = 'https://example-team.cloudflareaccess.com'
  AUDIENCE = 'wiki-application-audience'
  KEY = OpenSSL::PKey::RSA.generate(2048)
  SECOND_KEY = OpenSSL::PKey::RSA.generate(2048)
  VARIABLES = %w[PROJECTBOOK_MCP_ACCESS_ENABLED PROJECTBOOK_MCP_ACCESS_ISSUER
    PROJECTBOOK_MCP_ACCESS_AUDIENCE
    PROJECTBOOK_MCP_TOKEN PROJECTBOOK_MCP_DOCUMENT_WRITE PROJECTBOOK_MCP_MEMORY_WRITE
    PROJECTBOOK_PUBLIC_URL PROJECTBOOK_MCP_ENABLED].freeze

  def setup
    @previous = VARIABLES.to_h { |name| [name, ENV[name]] }
    VARIABLES.each { |name| ENV.delete(name) }
    ENV.update('PROJECTBOOK_MCP_ACCESS_ENABLED' => 'true',
      'PROJECTBOOK_MCP_ACCESS_ISSUER' => ISSUER,
      'PROJECTBOOK_MCP_ACCESS_AUDIENCE' => AUDIENCE)
    @access = Gollum::ProjectbookAccess.new
    @keys = {'first' => KEY.public_key}
    @fetches = 0
    @access.define_singleton_method(:fetch_keys) do |issuer|
      raise 'Unexpected issuer' unless issuer == ISSUER
      @test_fetch.call
    end
    @access.instance_variable_set(:@test_fetch, -> { @fetches += 1; @keys })
  end

  def teardown
    @previous.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
    FileUtils.remove_entry(@dir) if @dir
  end

  def claims
    {iss: ISSUER, aud: [AUDIENCE], sub: 'user-id', email: 'owner@example.test',
      iat: Time.now.to_i - 10, exp: Time.now.to_i + 300, type: 'app'}
  end

  def token(payload = claims, key: KEY, algorithm: 'RS256', kid: 'first')
    return JWT.encode(payload, key, algorithm, {kid: kid}) unless algorithm == 'RS256'
    # Sign independently of ruby-jwt's encoder, including deliberately invalid claims.
    encoded = [JSON.generate(alg: algorithm, kid: kid), JSON.generate(payload)].map do |part|
      Base64.urlsafe_encode64(part, padding: false)
    end.join('.')
    encoded + '.' + Base64.urlsafe_encode64(key.sign(OpenSSL::Digest::SHA256.new, encoded), padding: false)
  end

  def allowed?(assertion = token, extra = {})
    @access.authorized?({'HTTP_CF_ACCESS_JWT_ASSERTION' => assertion}.merge(extra))
  end

  def client
    return @client if @client
    @dir = Dir.mktmpdir('projectbook-access-')
    system('git', 'init', '-q', '-b', 'main', @dir, exception: true)
    wiki = Gollum::Wiki.new(@dir, ref: 'main')
    wiki.write_page('Home', :markdown, "# Access test book\n", message: 'Initial book')
    settings = Struct.new(:gollum_path, :wiki_options).new(@dir, {ref: 'main', allow_editing: true})
    endpoint = Gollum::ProjectbookMCP::Endpoint.new(->(_) { [404, {}, []] }, settings)
    endpoint.instance_variable_set(:@access, @access)
    @client = Rack::MockRequest.new(endpoint)
  end

  def rpc(method = 'tools/list', params = {}, headers = {})
    client.post('/mcp', {'HTTP_HOST' => '127.0.0.1:4567',
      'CONTENT_TYPE' => 'application/json', 'HTTP_ACCEPT' => 'application/json, text/event-stream',
      input: JSON.generate(jsonrpc: '2.0', id: 1, method: method, params: params)}.merge(headers))
  end

  def test_signed_identity_uses_access_policy_without_local_allowlist
    assert allowed?
    assert allowed?(token(claims.merge(email: 'another-policy-member@example.test')))
    assert_equal 1, @fetches
  end

  def test_rejects_bad_signature_algorithm_key_and_malformed_assertions
    assertions = [token(key: SECOND_KEY), token(algorithm: 'none', key: nil),
      token(algorithm: 'HS256', key: KEY.public_key.to_pem), token(kid: ''),
      token(kid: 'unknown'), token(kid: 'k' * 257), 'not.a.jwt', '', 'x' * 16_385, nil]
    assertions.each { |assertion| refute allowed?(assertion), 'Invalid assertion was accepted' }
    assert_equal 1, @fetches, 'Unknown IDs must not force unbounded network requests'
  end

  def test_rejects_invalid_claims_and_forwarded_email_spoofing
    bad = [{iss: 'https://attacker.cloudflareaccess.com'}, {aud: ['boat-audience']},
      {exp: Time.now.to_i - 1}, {iat: Time.now.to_i + 3600}, {nbf: Time.now.to_i + 3600},
      {email: ' '}, {email: ['owner@example.test']}, {sub: ''},
      {exp: (Time.now.to_i + 300).to_s}, {iat: (Time.now.to_i - 10).to_s},
      {exp: {}}, {nbf: []}, {aud: {}}, {email: nil}]
    bad.each do |changes|
      refute allowed?(token(claims.merge(changes)), 'HTTP_CF_ACCESS_AUTHENTICATED_USER_EMAIL' => 'owner@example.test'), changes.keys.inspect
    end
    %i[iss aud exp iat sub email].each do |missing|
      refute allowed?(token(claims.reject { |key, _| key == missing })), missing.to_s
    end
    refute allowed?(nil, 'HTTP_CF_ACCESS_AUTHENTICATED_USER_EMAIL' => 'owner@example.test')
  end

  def test_disabled_incomplete_and_untrusted_issuer_fail_closed
    %w[PROJECTBOOK_MCP_ACCESS_ISSUER PROJECTBOOK_MCP_ACCESS_AUDIENCE].each do |name|
      old = ENV[name]; ENV[name] = ''; refute allowed?; ENV[name] = old
    end
    ['http://example-team.cloudflareaccess.com', 'https://attacker.test',
     ISSUER + '/path', ISSUER + '@attacker.test', ISSUER + ':443', ISSUER + '?x=1'].each do |issuer|
      ENV['PROJECTBOOK_MCP_ACCESS_ISSUER'] = issuer
      refute allowed?
    end
    ENV['PROJECTBOOK_MCP_ACCESS_ISSUER'] = ISSUER
    ENV['PROJECTBOOK_MCP_ACCESS_ENABLED'] = 'false'
    refute allowed?
    assert_equal 0, @fetches
  end

  def test_key_rotation_expiry_and_outage_refresh_throttle
    now = 0.0
    Process.stub(:clock_gettime, ->(_) { now }) do
      assert allowed?
      @keys = {'second' => SECOND_KEY.public_key}
      refute allowed?(token(key: SECOND_KEY, kid: 'second'))
      now = 31.0
      assert allowed?(token(key: SECOND_KEY, kid: 'second'))
      refute allowed?
      assert_equal 2, @fetches
      @access.instance_variable_set(:@test_fetch, -> { @fetches += 1; raise IOError, 'offline' })
      now = 332.0
      refute allowed?(token(key: SECOND_KEY, kid: 'second')), 'Expired key cache must not survive fetch failure'
      refute allowed?(token(key: SECOND_KEY, kid: 'second'))
      assert_equal 3, @fetches
    end
  end

  def test_endpoint_requires_auth_even_without_static_token_and_keeps_bearer
    assert_equal 401, rpc.status
    assert_equal 401, rpc('tools/list', {}, 'HTTP_CF_ACCESS_AUTHENTICATED_USER_EMAIL' => 'owner@example.test').status
    headers = {'HTTP_CF_ACCESS_JWT_ASSERTION' => token, 'HTTP_AUTHORIZATION' => 'Bearer opaque-cloudflare-token'}
    initialize = rpc('initialize', {protocolVersion: '2025-03-26', capabilities: {}, clientInfo: {name: 'access-test', version: '1'}}, headers)
    assert_equal 200, initialize.status, initialize.body
    assert_equal 'projectbook', JSON.parse(initialize.body).dig('result', 'serverInfo', 'name')
    response = rpc('tools/call', {name: 'get_book_context', arguments: {}}, headers)
    assert_equal 200, response.status, response.body
    assert_includes response.body, 'Access test book'
    ENV['PROJECTBOOK_MCP_TOKEN'] = 'internal-test-token'
    assert_equal 200, rpc('tools/list', {}, 'HTTP_AUTHORIZATION' => 'Bearer internal-test-token').status
    assert_equal 401, rpc('tools/list', {}, 'HTTP_AUTHORIZATION' => 'Bearer wrong').status
    ENV['PROJECTBOOK_MCP_ACCESS_ENABLED'] = 'false'
    assert_equal 401, rpc('tools/list', {}, headers).status
    ENV.delete('PROJECTBOOK_MCP_TOKEN')
    assert_equal 200, rpc.status, 'Legacy anonymous local mode is unchanged when Access is disabled'
  end

  def test_access_does_not_bypass_write_host_origin_or_disabled_guards
    headers = {'HTTP_CF_ACCESS_JWT_ASSERTION' => token}
    ENV['PROJECTBOOK_MCP_DOCUMENT_WRITE'] = ENV['PROJECTBOOK_MCP_MEMORY_WRITE'] = 'false'
    response = rpc('tools/list', {}, headers)
    names = JSON.parse(response.body).dig('result', 'tools').map { |tool| tool['name'] }
    assert_includes names, 'read_document'
    refute_includes names, 'save_document'
    refute_includes names, 'save_agent_note'
    denied = rpc('tools/call', {name: 'save_document', arguments: {}}, headers)
    assert JSON.parse(denied.body)['error']
    assert_equal 403, rpc('tools/list', {}, headers.merge('HTTP_HOST' => 'attacker.test')).status
    assert_equal 403, rpc('tools/list', {}, headers.merge('HTTP_ORIGIN' => 'https://attacker.test')).status
    ENV['PROJECTBOOK_MCP_ENABLED'] = 'false'
    assert_equal 404, rpc('tools/list', {}, headers).status
  end

  # Exercise the actual JWKS parser and HTTP safeguards, not a stubbed public key.
  class FakeHTTP
    attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout
    attr_reader :path
    def initialize(body, status = '200')
      @body, @status = body, status
    end
    def start; yield self; end
    def request(request)
      @path = request.path
      response = Net::HTTPResponse::CODE_TO_OBJ.fetch(@status).new('1.1', @status, 'test')
      body = @body
      response.define_singleton_method(:read_body) { |&block| block.call(body) }
      yield response
    end
  end

  def test_fetch_keys_uses_pinned_https_and_imports_public_rsa_keys
    jwk = JWT::JWK.new(KEY, kid: 'first', use: 'sig', alg: 'RS256').export
    http = FakeHTTP.new(JSON.generate(keys: [jwk, jwk.merge(kid: 'ignored', use: 'enc')]))
    access = Gollum::ProjectbookAccess.new
    Net::HTTP.stub(:new, ->(host, port, proxy) {
      assert_equal 'example-team.cloudflareaccess.com', host
      assert_equal 443, port
      assert_nil proxy
      http
    }) do
      keys = access.send(:fetch_keys, ISSUER)
      assert_equal ['first'], keys.keys
      assert_equal KEY.public_key.to_pem, keys['first'].to_pem
    end
    assert http.use_ssl
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_equal '/cdn-cgi/access/certs', http.path
    assert_equal 3, http.read_timeout
  end

  def test_key_fetch_refuses_redirects_oversized_and_invalid_key_sets
    access = Gollum::ProjectbookAccess.new
    [['redirect', '302'], ['x' * (Gollum::ProjectbookAccess::MAX_JWKS_BYTES + 1), '200']].each do |body, status|
      Net::HTTP.stub(:new, FakeHTTP.new(body, status)) do
        assert_raises(IOError) { access.send(:fetch_keys, ISSUER) }
      end
    end
    ['{"keys":null}', '{"keys":[]}', '{"keys":{}}'].each do |body|
      Net::HTTP.stub(:new, FakeHTTP.new(body)) do
        assert_raises(ArgumentError) { access.send(:fetch_keys, ISSUER) }
      end
    end
  end
end
