require 'minitest/autorun'
require 'rack/mock'
require 'tmpdir'
require 'fileutils'
require 'gollum/projectbook_settings'

class SettingsTest < Minitest::Test
  def setup
    @settings_dir = Dir.mktmpdir
    ENV['PROJECTBOOK_SETTINGS_FILE'] = File.join(@settings_dir, 'settings.json')
    @endpoint = Gollum::ProjectbookSettings::Endpoint.new(->(_) { [204, {}, []] })
    @client = Rack::MockRequest.new(@endpoint)
    ENV['PROJECTBOOK_RAG_URL'] = 'http://rag:8090'
    ENV['PROJECTBOOK_SETTINGS_ADMIN'] = 'true'
  end
  def teardown
    FileUtils.remove_entry(@settings_dir)
    %w[PROJECTBOOK_RAG_URL PROJECTBOOK_SETTINGS_ADMIN PROJECTBOOK_SETTINGS_FILE].each { |key| ENV.delete(key) }
  end
  def post(overrides = {})
    @client.post('/gollum/projectbook/settings', {'HTTP_HOST'=>'127.0.0.1:4570','HTTP_X_PROJECTWIKI_REQUEST'=>'1','CONTENT_TYPE'=>'application/json',input:'{}'}.merge(overrides))
  end
  def test_writes_require_admin_same_origin_and_explicit_header
    @endpoint.stub(:backend, ->(*) { flunk 'Unsafe request forwarded' }) do
      assert_equal 403, post('HTTP_ORIGIN'=>'https://evil.example').status
      assert_equal 403, post('HTTP_X_PROJECTWIKI_REQUEST'=>nil).status
      assert_equal 403, post('HTTP_HOST'=>'evil.example').status
      ENV['PROJECTBOOK_SETTINGS_ADMIN']='false'
      assert_equal 403, post.status
    end
  end
  def test_navigation_settings_persist_without_rag_and_check_versions
    ENV.delete('PROJECTBOOK_RAG_URL')
    url='/gollum/projectbook/settings/navigation'
    state=JSON.parse(@client.get(url,'HTTP_HOST'=>'localhost').body)
    assert_equal true,state['confirm_move']
    headers={'HTTP_HOST'=>'localhost','CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1',input:JSON.generate(version:state['version'],confirm_move:false)}
    assert_equal 200,@client.post(url,headers).status
    assert_equal false,JSON.parse(@client.get(url,'HTTP_HOST'=>'localhost').body)['confirm_move']
    assert_equal 409,@client.post(url,headers).status
    assert_equal false,JSON.parse(File.read(ENV['PROJECTBOOK_SETTINGS_FILE']))['confirm_move']
    assert_equal 403,@client.post(url,headers.merge('HTTP_ORIGIN'=>'https://evil.example')).status
  end
  def test_settings_forwarding_and_conflicts
    @endpoint.stub(:backend, [200, {'settings'=>{'enabled'=>false}, 'version'=>'test'}]) do
      r=post('HTTP_ORIGIN'=>'http://127.0.0.1:4570')
      assert_equal 200,r.status; assert JSON.parse(r.body)['editable']
      assert_equal 'no-store',r['cache-control']
    end
    @endpoint.stub(:backend, [409, {'error'=>'Settings changed'}]) { assert_equal 409,post.status }
  end
  def test_uninstalled_and_unavailable_are_distinct_and_read_only
    ENV.delete('PROJECTBOOK_RAG_URL')
    r=@client.get('/gollum/projectbook/settings','HTTP_HOST'=>'localhost')
    assert_equal 200,r.status; refute JSON.parse(r.body)['available']
    ENV['PROJECTBOOK_RAG_URL']='http://rag:8090'
    @endpoint.stub(:backend, ->(*) { raise Errno::ECONNREFUSED }) do
      r=@client.get('/gollum/projectbook/settings','HTTP_HOST'=>'localhost')
      assert_equal 503,r.status; assert JSON.parse(r.body)['available']
      refute JSON.parse(r.body)['editable']
    end
  end
end
