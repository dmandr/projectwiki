require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV'] = 'test'
require 'gollum/app'

class TitlesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('projectwiki-titles-')
    system('git', 'init', '-q', '-b', 'main', @dir, exception: true)
    wiki.write_file('Home.md', "# Home\n", message: 'Fixture')
    Precious::App.set :gollum_path, @dir
    Precious::App.set :wiki_options, {ref: 'main', allow_editing: true, h1_title: true}
    @client = Rack::MockRequest.new(Precious::App)
  end
  def teardown; FileUtils.remove_entry(@dir); end
  def wiki; Gollum::Wiki.new(@dir, ref: 'main'); end
  def head; wiki.commit_for('main').id; end
  def create(title, path)
    @client.post('/gollum/projectbook/new', 'CONTENT_TYPE'=>'application/json', 'HTTP_X_PROJECTWIKI_REQUEST'=>'1', input: {kind:'document', title:title, path:path}.to_json)
  end
  def test_create_title_and_nested_path_then_edit
    before = head
    response = create('engine-check', 'new-folder/log/engine-check.md')
    assert_equal 200, response.status, response.body
    assert_equal '/gollum/edit/new-folder/log/engine-check.md', JSON.parse(response.body)['url']
    assert_equal before, wiki.commit_for('main').parent.id
    assert_equal "# Engine Check\n\n", File.read(File.join(@dir, 'new-folder/log/engine-check.md'))
    assert_equal 200, @client.get(JSON.parse(response.body)['url']).status
    after = head
    assert_equal 409, create('Other', 'new-folder/log/engine-check.md').status
    assert_equal after, head
  end
  def test_missing_path_requires_confirmation_and_get_never_writes
    before = head
    response = @client.get('/new-folder/engine_check')
    assert_equal 200, response.status, response.body
    assert_includes response.body, 'Document not found'
    assert_includes response.body, 'new-folder/engine_check.md'
    assert_includes response.body, 'Engine Check'
    assert_equal before, head
    refute File.exist?(File.join(@dir, 'new-folder'))
  end
  def test_title_round_trip_is_safe_and_path_remains_independent
    title = 'Русский *текст* <img src=x> & [link](url)'
    response = create(title, 'russian.md')
    assert_equal 200, response.status, response.body
    assert_equal title, Gollum::ProjectbookTitles.title(wiki.page('russian.md').text_data, 'russian.md')
    assert_equal 422, create("Bad\nTitle", 'bad.md').status
    assert_equal 422, create('Traversal', '../escape.md').status
    assert_equal 409, create('Case', 'home.md').status
    Precious::App.set :wiki_options, {ref:'main', allow_editing:false}
    assert_equal 403, create('Read only', 'readonly.md').status
  end
  def test_fallback_and_navigation_cache_refresh_and_duplicate_titles
    wiki.write_file('old-file.md', 'Body without heading', message:'Fixture')
    wiki.write_file('another.md', '# Same', message:'Fixture')
    wiki.write_file('one-more.md', '# Same', message:'Fixture')
    entries = Gollum::NavigationIndex.for(wiki).entries
    assert_equal 'Old File', entries.find { |e| e.url_path == 'old-file.md' }.title
    assert_equal 2, entries.count { |e| e.title == 'Same' }
    page = wiki.page('old-file.md')
    wiki.update_page(page, page.name, :markdown, '# Explicit title', message:'Change')
    assert_equal 'Explicit title', Gollum::NavigationIndex.for(wiki).entries.find { |e| e.url_path == 'old-file.md' }.title
    assert_includes @client.get('/old-file.md').body, 'Explicit title'
  end
  def test_missing_heading_is_added_on_save_without_dropping_body_or_metadata
    input = {'path'=>'missing-title.md', 'create'=>true, 'content'=>'Body'}
    Gollum::ProjectbookSave.save(wiki, input, [], {message:'Save'})
    assert_equal "# Missing Title\n\nBody", wiki.page('missing-title.md').text_data
    source = "---\ntags: boat\n---\n\nBody"
    normalized = Gollum::ProjectbookTitles.ensure_title(source, 'some-name.md')
    assert normalized.start_with?("---\ntags: boat\n---\n")
    assert_equal 'Some Name', Gollum::ProjectbookTitles.title(normalized, 'some-name.md')
    assert normalized.end_with?('Body')
    assert_equal '# Keep **formatting**', Gollum::ProjectbookTitles.ensure_title('# Keep **formatting**', 'other.md')
  end
end
