require 'minitest/autorun'
require 'rack/mock'
require 'tmpdir'
require 'fileutils'
require 'gollum/projectbook_editing'
class EditingTest < Minitest::Test
  def setup
    @dir=Dir.mktmpdir; ENV['PROJECTBOOK_SETTINGS_FILE']=File.join(@dir,'settings.json');ENV['PROJECTBOOK_MCP_TOKEN']='test'
    @client=Rack::MockRequest.new(Gollum::ProjectbookEditing::Endpoint.new(->(_){[204,{},[]]}))
    @id='12345678-1234-1234-1234-123456789012'
  end
  def teardown
    FileUtils.remove_entry(@dir);%w[PROJECTBOOK_SETTINGS_FILE PROJECTBOOK_MCP_TOKEN].each{|k|ENV.delete(k)}
  end
  def post(action,internal=false,extra={})
    @client.post('/gollum/projectbook/editing',{'CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1', 'HTTP_AUTHORIZATION'=>internal ? 'Bearer test' : '', input:JSON.generate({action:action,session:@id}.merge(extra))})
  end
  def test_editor_fence_and_release
    assert_equal 200,post('heartbeat').status
    assert_equal 409,post('prepare',true).status
    assert_equal 200,post('close').status
    assert_equal 200,post('prepare',true).status
    assert_equal 409,post('heartbeat').status
    assert_equal 200,post('resume',true).status
    assert_equal 200,post('heartbeat').status
  end
  def test_authorization_and_origin
    assert_equal 403,post('prepare').status
    response=@client.post('/gollum/projectbook/editing',{'CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1','HTTP_ORIGIN'=>'https://evil.example',input:JSON.generate(action:'heartbeat',session:@id)})
    assert_equal 403,response.status
  end
  def test_expired_editor_is_released_and_fence_survives_restart
    post('heartbeat')
    path=ENV['PROJECTBOOK_SETTINGS_FILE']+'.editors';File.write(path,JSON.generate(sessions:{@id=>Time.now.to_f-1}))
    assert_equal 200,post('prepare',true).status
    @client=Rack::MockRequest.new(Gollum::ProjectbookEditing::Endpoint.new(->(_){[204,{},[]]}))
    assert_equal 409,post('heartbeat').status
  end
end
