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
    %w[PROJECTBOOK_MCP_TOKEN PROJECTBOOK_MCP_MEMORY_WRITE PROJECTBOOK_MCP_ENABLED].each { |key| ENV.delete(key) }
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
  def test_protocol_discovery_resource_and_origin_guards
    response = rpc('initialize', {protocolVersion: '2025-03-26', capabilities: {}, clientInfo: {name: 'test', version: '1'}})
    assert_equal 200, response.status, response.body
    assert_equal 'projectbook', JSON.parse(response.body).dig('result', 'serverInfo', 'name')
    result = JSON.parse(rpc('tools/list').body).fetch('result')
    assert_equal 9, result.fetch('tools').length
    refute result['tools'].any? { |t| t['name'] == 'save_document' }
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
