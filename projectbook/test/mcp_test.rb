require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV'] = 'test'
require 'gollum/app'

class ProjectbookMCPTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('projectbook-mcp-')
    system('git', 'init', '-q', '-b', 'main', @dir, exception: true)
    @wiki = Gollum::Wiki.new(@dir, ref: 'main')
    @wiki.write_page('Home', :markdown, "# Test book\n\nBoat manuals.\n", message: 'Initial book')
    @wiki.write_page('hardware/engine', :markdown, "# Двигатель\n\nCooling pump impeller.\n- [ ] Check coolant\n", message: 'Engine manual')
    @old = head
    Precious::App.set :gollum_path, @dir
    Precious::App.set :wiki_options, {ref: 'main', allow_editing: true, allow_uploads: true}
    @client = Rack::MockRequest.new(Precious::App)
  end
  def teardown
    %w[PROJECTBOOK_MCP_TOKEN PROJECTBOOK_MCP_MEMORY_WRITE PROJECTBOOK_MCP_DOCUMENT_WRITE PROJECTBOOK_MCP_ENABLED PROJECTBOOK_RAG_URL].each { |key| ENV.delete(key) }
    FileUtils.remove_entry(@dir)
  end
  def wiki; Gollum::Wiki.new(@dir, ref: 'main'); end
  def head; wiki.commit_for('main').id; end
  def change_engine(content)
    w = wiki
    Gollum::ProjectbookSave.save(w, {'path' => 'hardware/engine.md', 'content' => content, 'etag' => w.page('hardware/engine').sha}, [], {message: 'Changed engine'})
  end
  def rpc(method, params = {}, headers = {})
    @client.post('/mcp', {'HTTP_HOST' => '127.0.0.1:4569', 'CONTENT_TYPE' => 'application/json', 'HTTP_ACCEPT' => 'application/json, text/event-stream', input: JSON.generate(jsonrpc: '2.0', id: 1, method: method, params: params)}.merge(headers))
  end
  def tool(name, args = {})
    response = rpc('tools/call', {name: name, arguments: args})
    assert_equal 200, response.status, response.body
    result = JSON.parse(response.body)
    refute result['error'], result.inspect
    body = result.fetch('result')
    [JSON.parse(body.fetch('content').first.fetch('text')), body['isError']]
  end
  def note
    {id: '12345678-1234-1234-1234-123456789012', scope: 'hardware', kind: 'summary', title: 'Cooling findings', content: 'Check the impeller before testing cooling.', sources: [{path: 'hardware/engine.md', sha: wiki.page('hardware/engine').sha}], expected_version: '', agent: 'test-agent'}
  end
  def browser_save(content, version)
    @client.post('/gollum/projectbook/save', 'HTTP_X_PROJECTWIKI_REQUEST' => '1',
      params: {document: JSON.generate(path: 'Home.md', content: content, etag: version)})
  end
  def test_document_preview_create_update_and_noop
    input = {path: 'notes/new.md', content: "A new document.\n", expected_version: ''}
    preview, error = tool('save_document', input); refute error
    assert preview['dry_run']; assert preview['created']; assert_includes preview['diff'], '+A new document.'
    assert_equal @old, head; refute File.exist?(File.join(@dir, input[:path]))
    saved, error = tool('save_document', input.merge(dry_run: false)); refute error
    doc, = tool('read_document', {path: input[:path]})
    assert_equal saved['version'], doc['sha']; assert_match(/^# /, doc['content'])
    after = head
    _, error = tool('save_document', input.merge(dry_run: false)); assert error
    assert_equal after, head
    result, error = tool('save_document', input.merge(content: doc['content'], expected_version: doc['sha'], dry_run: false))
    refute error; assert result['unchanged']; assert_equal after, head
  end
  def test_browser_then_agent_and_agent_then_browser_conflict
    original = wiki.page('Home').sha
    input = {path: 'Home.md', content: "# Agent\n", expected_version: original}
    _, error = tool('save_document', input); refute error
    response = browser_save("# Browser\n", original)
    assert_equal 200, response.status, response.body
    after_browser = head
    conflict, error = tool('save_document', input.merge(dry_run: false)); assert error
    assert_equal 412, conflict['status']; assert_equal wiki.page('Home').sha, conflict['current_version']
    assert_equal after_browser, head; assert_equal "# Browser\n", wiki.page('Home').text_data
    browser_version = wiki.page('Home').sha
    saved, error = tool('save_document', input.merge(expected_version: browser_version, dry_run: false)); refute error
    assert_equal saved['commit'], head
    response = browser_save("# Stale browser\n", browser_version)
    assert_equal 412, response.status, response.body
    assert_equal saved['commit'], head; assert_equal "# Agent\n", wiki.page('Home').text_data
  end
  def test_exact_edits_are_atomic_and_preserve_rest_of_document
    path = 'hardware/engine.md'; version = wiki.page(path).sha
    edits = [{old_text: 'Двигатель', new_text: 'Основной двигатель'}, {old_text: '- [ ] Check coolant', new_text: '- [x] Check coolant'}]
    input = {path: path, expected_version: version, edits: edits}
    preview, error = tool('edit_document', input); refute error
    assert preview['dry_run']; assert_equal @old, head
    _, error = tool('edit_document', input.merge(edits: edits + [{old_text: 'missing', new_text: 'x'}], dry_run: false)); assert error
    assert_equal @old, head
    _, error = tool('edit_document', input.merge(edits: [{old_text: 'e', new_text: 'x'}], dry_run: false)); assert error
    assert_equal @old, head
    saved, error = tool('edit_document', input.merge(dry_run: false)); refute error
    assert_equal "# Основной двигатель\n\nCooling pump impeller.\n- [x] Check coolant\n", wiki.page(path).text_data
    assert_equal saved['version'], wiki.page(path).sha
    _, error = tool('edit_document', input.merge(dry_run: false)); assert error
    assert_equal saved['commit'], head
  end
  def test_document_path_disk_and_read_only_guards
    input = {path: 'Home.md', content: "# Agent\n", expected_version: wiki.page('Home').sha, dry_run: false}
    File.write(File.join(@dir, 'Home.md'), 'unsaved local work')
    conflict, error = tool('save_document', input); assert error; assert_equal 409, conflict['status']
    assert_equal 'unsaved local work', File.read(File.join(@dir, 'Home.md'))
    File.symlink('/tmp', File.join(@dir, 'alias'))
    ['../escape.md', '.projectbook/secret.md', '_Sidebar.md', 'alias/new.md'].each do |path|
      _, error = tool('save_document', input.merge(path: path, expected_version: '')); assert error
    end
    assert_equal @old, head
    ENV['PROJECTBOOK_MCP_DOCUMENT_WRITE'] = 'false'
    list = JSON.parse(rpc('tools/list').body).dig('result', 'tools')
    refute list.any? { |t| %w[save_document edit_document save_todos].include?(t['name']) }
    assert list.any? { |t| t['name'] == 'save_agent_note' }
    %w[save_document edit_document save_todos].each do |name|
      denied = JSON.parse(rpc('tools/call', {name: name, arguments: input}).body)
      assert denied['error']
    end
    ENV.delete('PROJECTBOOK_MCP_DOCUMENT_WRITE')
    Precious::App.set :wiki_options, {ref: 'main', allow_editing: false}
    list = JSON.parse(rpc('tools/list').body).dig('result', 'tools')
    refute list.any? { |t| %w[save_document edit_document save_todos save_agent_note append_raw_note].include?(t['name']) }
  end
  def test_configured_public_host_preserves_origin_guard
    previous = ENV['PROJECTBOOK_PUBLIC_URL']
    ENV['PROJECTBOOK_PUBLIC_URL'] = 'https://book.example.test'
    assert_equal 200, rpc('tools/list', {}, 'HTTP_HOST' => 'book.example.test', 'HTTP_ORIGIN' => 'https://book.example.test').status
    assert_equal 403, rpc('tools/list', {}, 'HTTP_HOST' => 'evil.example.test').status
    assert_equal 403, rpc('tools/list', {}, 'HTTP_HOST' => 'book.example.test', 'HTTP_ORIGIN' => 'https://evil.example.test').status
  ensure
    previous ? ENV['PROJECTBOOK_PUBLIC_URL'] = previous : ENV.delete('PROJECTBOOK_PUBLIC_URL')
  end
  def test_protocol_discovery_resource_and_origin_guards
    response = rpc('initialize', {protocolVersion: '2025-03-26', capabilities: {}, clientInfo: {name: 'test', version: '1'}})
    assert_equal 200, response.status, response.body
    assert_equal 'projectbook', JSON.parse(response.body).dig('result', 'serverInfo', 'name')
    result = JSON.parse(rpc('tools/list').body).fetch('result')
    assert_equal 23, result.fetch('tools').length
    assert result['tools'].any? { |t| t['name'] == 'save_document' }
    response = rpc('resources/read', {uri: 'projectbook://book/context'})
    result = JSON.parse(response.body)
    refute result['error'], result.inspect
    assert_includes JSON.generate(result), 'Test book'
    assert_equal 403, rpc('tools/list', {}, 'HTTP_ORIGIN' => 'https://evil.example').status
    assert_equal 403, rpc('tools/list', {}, 'HTTP_HOST' => 'evil.example').status
    ENV['PROJECTBOOK_MCP_TOKEN'] = 'test-token'
    assert_equal 401, rpc('tools/list').status
    assert_equal 200, rpc('tools/list', {}, 'HTTP_AUTHORIZATION' => 'Bearer test-token').status
    ENV.delete('PROJECTBOOK_MCP_TOKEN')
    invalid = JSON.parse(rpc('tools/call', {name: 'list_tree', arguments: {limit: 1000}}).body)
    assert invalid.dig('result', 'isError')
  end
  def test_experimental_search_discovery_staleness_and_pdf_urls
    list = JSON.parse(rpc('tools/list').body).dig('result', 'tools')
    refute list.any? { |t| t['name'] == 'search_knowledge' }
    ENV['PROJECTBOOK_RAG_URL'] = 'http://rag:8090'
    list = JSON.parse(rpc('tools/list').body).dig('result', 'tools')
    assert list.any? { |t| t['name'] == 'search_knowledge' }
    refute list.find { |t| t['name'] == 'search_knowledge' }.dig('inputSchema', 'properties').key?('revision')
    book = Gollum::ProjectbookKnowledge.new(wiki, base_url: 'http://localhost:4570')
    response = {'indexed_revision' => 'old', 'items' => [
      {'path' => 'Home.md', 'sha' => wiki.page('Home').sha, 'type' => 'markdown'},
      {'path' => 'manual.pdf', 'sha' => 'old', 'type' => 'pdf', 'page' => 2}]}
    book.stub(:rag_request, response) do
      result = book.search_knowledge(query: 'engine')
      assert result['stale']; refute result['items'][0]['stale']; assert result['items'][1]['stale']
      assert_equal 'http://localhost:4570/gollum/file/manual.pdf', result['items'][1]['url']
    end
    ENV.delete('PROJECTBOOK_RAG_URL')
    error = assert_raises(Gollum::ProjectbookCreation::Error) { book.get_search_index_status }
    assert_equal 503, error.status
  end
  def test_map_tree_search_read_history_and_snapshot
    map, error = tool('get_book_context'); refute error
    assert_equal 2, map['documents']
    tree, = tool('list_tree', {depth: 2, limit: 2})
    assert_equal 3, tree['total']; assert_equal 2, tree['next_offset']
    matches, = tool('search_documents', {query: 'двигатель impeller'})
    assert_equal 1, matches['total']
    assert_equal 3, matches['items'][0]['matches'][1]['line']
    doc, = tool('read_document', {path: 'hardware/engine.md', start_line: 3, line_count: 1})
    assert_equal "Cooling pump impeller.\n", doc['content']
    before = head
    change_engine("# Engine new\n\nNew version\n")
    old, = tool('read_document', {path: 'hardware/engine.md', revision: before})
    assert_includes old['content'], 'impeller'
    history, = tool('get_history', {path: 'hardware/engine.md'})
    assert_equal 'Changed engine', history['items'].first['message']
    diff, = tool('get_diff', {path: 'hardware/engine.md', from_revision: before})
    assert_includes diff['diff'], '+New version'
    _, error = tool('read_document', {path: '../outside.md'}); assert error
    assert_equal 'main', `git -C #{@dir} branch --show-current`.strip
  end
  def test_notes_save_replay_scope_inheritance_and_staleness
    input = note; before = head
    saved, error = tool('save_agent_note', input); refute error
    refute_equal before, head
    after = head
    assert_equal [Gollum::ProjectbookKnowledge::MEMORY + input[:id] + '.json'], `git -C #{@dir} diff-tree --no-commit-id --name-only -r HEAD`.lines.map(&:strip)
    again, error = tool('save_agent_note', input); refute error
    assert again['unchanged']; assert_equal after, head
    found, = tool('list_agent_notes', {scope: 'hardware/engine.md'})
    assert_equal 1, found['total']; refute found['items'][0]['stale']
    _, error = tool('save_agent_note', input.merge(content: 'Overwrite', expected_version: 'bad')); assert error
    assert_equal after, head
    updated, error = tool('save_agent_note', input.merge(content: 'Revised finding', expected_version: saved['version'])); refute error
    refute_equal saved['version'], updated['version']
    change_engine("# Engine\nChanged\n")
    read, = tool('read_agent_note', {id: input[:id]})
    assert read['stale']
    _, error = tool('save_agent_note', input.merge(content: 'Old-source summary', expected_version: updated['version'])); assert error
    refute Gollum::NavigationIndex.for(wiki).entries.any? { |e| e.path.start_with?('.projectbook/') }
  end
  def test_memory_symlink_uncommitted_and_read_only_protection
    input = note
    File.symlink('/tmp', File.join(@dir, '.projectbook'))
    _, error = tool('save_agent_note', input); assert error
    assert_equal @old, head
    File.unlink(File.join(@dir, '.projectbook'))
    target = File.join(@dir, Gollum::ProjectbookKnowledge::MEMORY + input[:id] + '.json')
    FileUtils.mkdir_p(File.dirname(target)); File.write(target, 'local work')
    _, error = tool('save_agent_note', input); assert error
    assert_equal 'local work', File.read(target)
    ENV['PROJECTBOOK_MCP_MEMORY_WRITE'] = 'false'
    list = JSON.parse(rpc('tools/list').body).dig('result', 'tools')
    refute list.any? { |t| t['name'] == 'save_agent_note' }
    denied = JSON.parse(rpc('tools/call', {name: 'save_agent_note', arguments: input}).body)
    assert denied['error'], 'A hidden write tool must also be uncallable'
    ENV.delete('PROJECTBOOK_MCP_MEMORY_WRITE')
    Precious::App.set :wiki_options, {ref: 'main', allow_editing: false}
    list = JSON.parse(rpc('tools/list').body).dig('result', 'tools')
    refute list.any? { |t| t['name'] == 'save_agent_note' }
    assert_equal @old, head
  end
end
