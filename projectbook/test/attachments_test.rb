require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV'] = 'test'
require 'gollum/app'

class ProjectbookAttachmentsTest < Minitest::Test
  def pdf_bytes(texts)
    objects = ['<< /Type /Catalog /Pages 2 0 R >>', nil, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    kids = []
    texts.each do |text|
      page_id = objects.length + 1; kids << "#{page_id} 0 R"
      objects << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents #{page_id + 1} 0 R >>"
      stream = "BT /F1 12 Tf 30 700 Td (#{text}) Tj ET\n"
      objects << "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream"
    end
    objects[1] = "<< /Type /Pages /Count #{texts.length} /Kids [#{kids.join(' ')}] >>"
    out = "%PDF-1.4\n".b; offsets = [0]
    objects.each_with_index { |body, i| offsets << out.bytesize; out << "#{i + 1} 0 obj\n#{body}\nendobj\n" }
    xref = out.bytesize
    out << "xref\n0 #{offsets.length}\n0000000000 65535 f \n"
    offsets.drop(1).each { |offset| out << format('%010d 00000 n ', offset) + "\n" }
    out << "trailer\n<< /Size #{offsets.length} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  end
  def setup
    @dir = Dir.mktmpdir('projectbook-pdf-')
    system('git', 'init', '-q', '-b', 'main', @dir, exception: true)
    @path = 'manuals/Двигатель test.pdf'
    FileUtils.mkdir_p(File.join(@dir, 'manuals'))
    @bytes = pdf_bytes(['Engine cooling pump', '', 'Oil capacity five litres'])
    File.binwrite(File.join(@dir, @path), @bytes)
    File.binwrite(File.join(@dir, 'binary.dat'), "\x00\xff\xfe\x80".b * 40000)
    File.write(File.join(@dir, '.hidden.pdf'), @bytes)
    File.write(File.join(@dir, 'broken.pdf'), 'not a PDF')
    File.symlink('/etc/passwd', File.join(@dir, 'link.pdf'))
    commit
    @revision = book.revision
    Precious::App.set :gollum_path, @dir
    Precious::App.set :wiki_options, {ref: 'main', allow_editing: true}
    @client = Rack::MockRequest.new(Precious::App)
  end
  def teardown
    FileUtils.remove_entry(@dir)
  end
  def commit
    system('git', '-C', @dir, 'add', '.', exception: true)
    system('git', '-C', @dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Fixture', exception: true)
  end
  def book(revision = nil)
    Gollum::ProjectbookKnowledge.new(Gollum::Wiki.new(@dir, ref: 'main'), revision: revision)
  end
  def rpc(method, params)
    r = @client.post('/mcp', 'HTTP_HOST' => '127.0.0.1:4569', 'CONTENT_TYPE' => 'application/json',
      'HTTP_ACCEPT' => 'application/json, text/event-stream', input: JSON.generate(jsonrpc: '2.0', id: 1, method: method, params: params))
    assert_equal 200, r.status
    JSON.parse(r.body)
  end
  def test_whole_pdf_ranges_and_dense_page_continuation
    all = book.read_pdf_text(path: @path)
    assert all[:complete]; assert_equal 3, all[:total_pages]
    assert_equal [1, 2, 3], all[:pages].map { |p| p[:page] }
    assert all[:pages][1][:empty]
    assert_includes all[:pages][0][:text], 'Engine cooling pump'
    ranged = book.read_pdf_text(path: @path, start_page: 3, end_page: 3)
    assert_equal [3], ranged[:pages].map { |p| p[:page] }
    texts = Hash.new(''); page = 1; offset = 0
    30.times do
      part = book(@revision).read_pdf_text(path: @path, start_page: page, page_offset: offset, max_chars: 7)
      part[:pages].each { |p| texts[p[:page]] += p[:text] }
      break if part[:complete]
      page, offset = part.values_at(:next_page, :next_page_offset)
    end
    assert_equal all[:pages].to_h { |p| [p[:page], p[:text]] }, texts
    assert_raises(Gollum::ProjectbookCreation::Error) { book.read_pdf_text(path: @path, start_page: 4) }
    assert_raises(Gollum::ProjectbookCreation::Error) { book.read_pdf_text(path: @path, page_offset: 1000) }
    assert_raises(Gollum::ProjectbookCreation::Error) { book.read_pdf_text(path: 'broken.pdf') }
  end
  def test_page_batch_continuation_and_snapshot
    File.binwrite(File.join(@dir, @path), pdf_bytes(Array.new(51) { |n| "Page #{n + 1}" })); commit
    first = book.read_pdf_text(path: @path)
    refute first[:complete]; assert_equal 51, first[:next_page]
    last = book(first[:revision]).read_pdf_text(path: @path, start_page: 51)
    assert last[:complete]; assert_equal 51, last[:pages][0][:page]
    assert_equal 3, book(@revision).read_pdf_text(path: @path)[:total_pages]
  end
  def test_raw_resource_and_byte_ranges_are_exact
    response = rpc('tools/call', name: 'read_attachment', arguments: {path: @path})
    refute response['error']; refute response.dig('result', 'isError')
    link = response.dig('result', 'content', 1)
    assert_equal 'resource_link', link['type']
    resource = rpc('resources/read', uri: link['uri'])
    refute resource['error'], resource.inspect
    assert_equal @bytes, Base64.strict_decode64(resource.dig('result', 'contents', 0, 'blob'))
    assert_equal 'application/pdf', resource.dig('result', 'contents', 0, 'mimeType')
    reconstructed = ''.b; offset = 0
    loop do
      part = book(@revision).read_attachment(path: 'binary.dat', format: 'bytes', offset: offset)
      reconstructed << Base64.strict_decode64(part[:data])
      offset = part[:next_offset]; break unless offset
    end
    assert_equal File.binread(File.join(@dir, 'binary.dat')), reconstructed
    assert_equal book.entries.find { |e| e[:path] == 'binary.dat' }[:sha], Digest::SHA1.hexdigest("blob #{reconstructed.bytesize}\0" + reconstructed)
    File.binwrite(File.join(@dir, @path), pdf_bytes(['Changed'])); commit
    historical = rpc('resources/read', uri: link['uri'])
    assert_equal @bytes, Base64.strict_decode64(historical.dig('result', 'contents', 0, 'blob'))
  end
  def test_visibility_validation_resource_auth_and_no_rag_dependency
    %w[../secret.pdf /etc/passwd .hidden.pdf link.pdf missing.pdf].each do |path|
      assert_raises(Gollum::ProjectbookCreation::Error) { book.read_attachment(path: path) }
    end
    assert_raises(Gollum::ProjectbookCreation::Error) { book.read_attachment(path: @path, format: 'bytes', offset: @bytes.bytesize + 1) }
    assert_raises(Gollum::ProjectbookCreation::Error) { book.read_attachment(path: @path, format: 'bytes', length: 100000) }
    malformed = rpc('resources/read', uri: "projectbook://attachments/#{@revision}/Li4vc2VjcmV0LnBkZg")
    assert malformed['error']
    result = rpc('tools/call', name: 'read_pdf_text', arguments: {path: @path, start_page: 1, end_page: 1})
    refute result.dig('result', 'isError'), result.inspect
    assert_includes JSON.parse(result.dig('result', 'content', 0, 'text'))['pages'][0]['text'], 'Engine'
    ENV['PROJECTBOOK_MCP_TOKEN'] = 'test'
    response = @client.post('/mcp', 'HTTP_HOST' => '127.0.0.1:4569', 'CONTENT_TYPE' => 'application/json',
      'HTTP_ACCEPT' => 'application/json, text/event-stream', input: JSON.generate(jsonrpc: '2.0', id: 1, method: 'resources/read', params: {uri: book.read_attachment(path: @path)[:uri]}))
    assert_equal 401, response.status
  ensure
    ENV.delete('PROJECTBOOK_MCP_TOKEN')
  end
end
