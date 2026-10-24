require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV'] = 'test'
require 'gollum/app'

class CreationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('projectwiki-creation-')
    system('git', 'init', '-q', '-b', 'main', @dir, exception: true)
    @wiki = Gollum::Wiki.new(@dir, ref: 'main')
    @wiki.write_page('Home', :markdown, '# Home', message: 'Fixture', name: 'Test', email: 'test@example.invalid')
    Precious::App.set :gollum_path, @dir
    Precious::App.set :wiki_options, {ref: 'main', allow_editing: true}
    @client = Rack::MockRequest.new(Precious::App)
  end
  def teardown
    FileUtils.remove_entry(@dir)
  end
  def request(kind, folder, name, extra = {})
    @client.post('/gollum/projectbook/new', {'CONTENT_TYPE' => 'application/json', 'HTTP_X_PROJECTWIKI_REQUEST' => '1', input: {kind: kind, folder: folder, name: name}.to_json}.merge(extra))
  end
  def head
    Gollum::Wiki.new(@dir, ref: 'main').commit_for('main').id
  end
  def test_folder_and_document_preflight
    response = request('folder', '', 'Sea notes')
    assert_equal 200, response.status, response.body
    assert_equal '/gollum/overview/Sea%20notes/', JSON.parse(response.body)['url']
    assert File.file?(File.join(@dir, 'Sea notes/.gitkeep'))
    before = head
    response = request('document', 'Sea notes', 'Заметка')
    assert_equal 200, response.status, response.body
    assert_includes JSON.parse(response.body)['url'], '/gollum/create/Sea%20notes/'
    assert_equal before, head, 'Document preflight must not create a commit'
    refute File.exist?(File.join(@dir, 'Sea notes/Заметка.md'))
    assert_equal 409, request('folder', '', 'Sea notes').status
    assert_equal 409, request('document', '', 'Home').status
    assert_equal before, head
  end
  def test_document_save_race_reports_conflict
    assert_equal 200, request('document', '', 'Race').status
    payload = {page: 'Race', path: '', format: 'markdown', content: 'First writer', message: 'Test save'}
    response = @client.post('/gollum/create', params: payload)
    assert_equal 303, response.status, response.body
    before = head
    response = @client.post('/gollum/create', params: payload.merge(content: 'Second writer'))
    assert_equal 409, response.status, response.body
    assert_equal before, head
    assert_equal 'First writer', File.read(File.join(@dir, 'Race.md'))
  end
  def test_invalid_requests_and_read_only_do_not_write
    before = head
    ['../escape', '.git', 'foo/bar', 'foo\\bar', 'hello%2fworld', ' x', '_Sidebar', 'bad?name'].each do |name|
      assert_equal 422, request('folder', '', name).status, name
    end
    assert_equal 422, request('folder', '../', 'escape').status
    assert_equal 404, request('document', 'missing', 'note').status
    assert_equal 403, request('folder', '', 'blocked', 'HTTP_X_PROJECTWIKI_REQUEST' => nil).status
    Precious::App.set :wiki_options, {ref: 'main', allow_editing: false}
    assert_equal 403, request('folder', '', 'readonly').status
    assert_equal before, head
  end
  def test_untracked_file_and_symlink_are_not_overwritten
    File.write(File.join(@dir, 'local.md'), 'unsaved')
    File.symlink('/tmp', File.join(@dir, 'linked'))
    assert_equal 409, request('document', '', 'local').status
    assert_equal 422, request('folder', '', 'linked').status
    assert_equal 'unsaved', File.read(File.join(@dir, 'local.md'))
  end
end
