require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV'] = 'test'
require 'gollum/app'

class EditorSaveTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('projectwiki-editor-')
    system('git', 'init', '-q', '-b', 'main', @dir, exception: true)
    @wiki = Gollum::Wiki.new(@dir, ref: 'main')
    @wiki.write_page('Home', :markdown, "# Home\n", message: 'Fixture')
    Precious::App.set :gollum_path, @dir
    Precious::App.set :wiki_options, {ref: 'main', allow_editing: true, allow_uploads: true}
    @client = Rack::MockRequest.new(Precious::App)
    @target = 'uploads/12345678-1234-1234-1234-123456789012/manual.pdf'
  end
  def teardown; FileUtils.remove_entry(@dir); end
  def wiki; Gollum::Wiki.new(@dir, ref: 'main'); end
  def head; wiki.commit_for('main').id; end
  def payload
    {path: 'Home.md', content: "# Edited\n\n[Manual](#{@target})\n", etag: wiki.page('Home').sha, create: false, attachments: [{path: @target}]}
  end
  def save(input, files = ["%PDF-1.4\x00\xff".b], header = '1')
    boundary = 'ProjectWikiBoundary'
    body = "--#{boundary}\r\nContent-Disposition: form-data; name=\"document\"\r\n\r\n#{JSON.generate(input)}\r\n".b
    files.each do |bytes|
      body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"files[]\"; filename=\"manual.pdf\"\r\nContent-Type: application/octet-stream\r\n\r\n".b << bytes.b << "\r\n"
    end
    body << "--#{boundary}--\r\n"
    @client.post('/gollum/projectbook/save', 'CONTENT_TYPE' => "multipart/form-data; boundary=#{boundary}", 'HTTP_X_PROJECTWIKI_REQUEST' => header, input: body)
  end
  def test_document_and_binary_are_one_commit_and_stale_retry_is_safe
    before = head
    input = payload
    response = save(input)
    assert_equal 200, response.status, response.body
    assert_equal before, wiki.commit_for('main').parent.id
    assert_equal input[:content], File.read(File.join(@dir, 'Home.md'))
    assert_equal "%PDF-1.4\x00\xff".b, File.binread(File.join(@dir, @target))
    after = head
    assert_equal 412, save(input).status
    assert_equal after, head
  end
  def test_invalid_attachment_does_not_change_document_or_head
    before = head
    ['../escape', 'uploads/../escape', 'uploads/12345678-1234-1234-1234-123456789012/.git'].each do |path|
      assert_equal 422, save(payload.merge(attachments: [{path: path}])).status
      assert_equal before, head
    end
    assert_equal "# Home\n", File.read(File.join(@dir, 'Home.md'))
  end
  def test_disabled_uploads_read_only_and_missing_header
    before = head
    assert_equal 403, save(payload, ['x'], nil).status
    Precious::App.set :wiki_options, {ref: 'main', allow_editing: true, allow_uploads: false}
    assert_equal 403, save(payload).status
    Precious::App.set :wiki_options, {ref: 'main', allow_editing: false, allow_uploads: true}
    assert_equal 403, save(payload).status
    assert_equal before, head
  end
  def test_existing_attachment_and_uncommitted_document_are_preserved
    FileUtils.mkdir_p(File.dirname(File.join(@dir, @target)))
    File.write(File.join(@dir, @target), 'local file')
    before = head
    assert_equal 409, save(payload).status
    File.write(File.join(@dir, 'Home.md'), 'local work')
    assert_equal 409, save(payload.merge(attachments: []), []).status
    assert_equal before, head
    assert_equal 'local work', File.read(File.join(@dir, 'Home.md'))
  end
  def test_create_collision_and_exact_source_noop
    before = head
    response = save(payload.merge(path: 'New.md', create: true))
    assert_equal 200, response.status, response.body
    assert_equal before, wiki.commit_for('main').parent.id
    after = head
    assert_equal 409, save(payload.merge(path: 'New.md', create: true)).status
    assert_equal after, head
    assert_equal 200, save(payload.merge(content: wiki.page('Home').text_data, attachments: []), []).status
    assert_equal after, head, 'Opening and saving unchanged source must not make a commit'
  end
  def test_conflict_and_size_limit_leave_no_attachment
    before = head
    assert_equal 412, save(payload.merge(etag: 'old')).status
    assert_equal 413, save(payload, ['x' * (Gollum::ProjectbookSave::MAX_FILE + 1)]).status
    assert_equal before, head
    refute File.exist?(File.join(@dir, @target))
  end
end
