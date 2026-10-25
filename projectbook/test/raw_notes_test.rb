require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV']='test'
require 'gollum/app'
class RawNotesTest < Minitest::Test
  ID='11111111-1111-4111-8111-111111111111'
  UP='22222222-2222-4222-8222-222222222222'
  def setup
    @dir=Dir.mktmpdir;@uploads=Dir.mktmpdir;ENV['PROJECTBOOK_RAW_UPLOADS']=@uploads
    system('git','init','-q','-b','main',@dir,exception:true)
    wiki.write_page('Home',:markdown,"# Home\n",message:'Fixture')
    Precious::App.set :gollum_path,@dir
    Precious::App.set :wiki_options,{ref:'main',allow_editing:true,allow_uploads:true}
    @client=Rack::MockRequest.new(Precious::App)
  end
  def teardown;FileUtils.remove_entry(@dir);FileUtils.remove_entry(@uploads);ENV.delete('PROJECTBOOK_RAW_UPLOADS');end
  def wiki;Gollum::Wiki.new(@dir,ref:'main');end
  def service;Gollum::ProjectbookRawNotes;end
  def snapshot;Gollum::ProjectbookKnowledge.new(wiki);end
  def head;wiki.commit_for('main').id;end
  def upload(bytes='test-photo')
    service.upload(wiki,upload_id:UP,offset:0,data:Base64.strict_encode64(bytes))
    {'upload_id'=>UP,'name'=>'photo.jpg','mime_type'=>'image/jpeg','sha256'=>Digest::SHA256.hexdigest(bytes)}
  end
  def test_atomic_commit_and_retry_and_read
    file=upload;before=head
    input={'id'=>ID,'title'=>'Engine measurement','text'=>'Width: 23 mm','attachments'=>[file]}
    result=service.create(wiki,input,{message:'capture'})
    assert_equal before,wiki.commit_for('main').parent.id
    assert_includes wiki.page(result['path']).text_data,'Width: 23 mm'
    assert ::File.file?(::File.join(@dir,result['attachments'][0]['path']))
    assert_equal 1,snapshot.list_raw_notes[:total]
    before=head
    assert service.create(wiki,input,{})['unchanged']
    assert_equal before,head
    assert_raises(service::Error){service.create(wiki,input.merge('text'=>'Changed'),{})}
    assert_equal 'unsorted',snapshot.read_raw_note(id:ID)['status']
  end
  def test_feed_newest_first_excerpt_and_attachment_order
    older=nil
    Time.stub(:now,Time.utc(2026,10,25,12,0,0)) do
      older=service.create(wiki,{'id'=>ID,'title'=>'Earlier','text'=>'Original note'},{})
    end
    metadata_path=older['path'].sub('note.md','.note.json')
    meta=JSON.parse(wiki.file(metadata_path).raw_data);meta['created_at']='2026-10-25T12:00:00Z'
    committer=Gollum::Committer.new(wiki,message:'Legacy timestamp')
    committer.add(metadata_path,JSON.generate(meta))
    committer.after_commit { |index,_| index.update_working_dir(metadata_path) };committer.commit
    newer=nil
    Time.stub(:now,Time.utc(2026,10,25,12,0,0)+0.25) do
      newer=service.create(wiki,{'id'=>'33333333-3333-4333-8333-333333333333','title'=>'Later','text'=>'Размер: 23 mm — [reference](Home.md)','attachments'=>[upload]},{})
    end
    items=snapshot.list_raw_notes[:items]
    assert_equal [newer['id'],older['id']],items.map{|n|n['id']}
    assert_equal 'Размер: 23 mm — reference',items.first['excerpt']
    refute_includes items.first['excerpt'],'photo-01'
  end
  def test_append_messages_preserves_content_attachments_and_retry
    note=service.create(wiki,{'id'=>ID,'text'=>'First message'},{})
    input={'id'=>ID,'message_id'=>'44444444-4444-4444-8444-444444444444','expected_version'=>note['document_version'],'text'=>'Second message','attachments'=>[upload]}
    before=head;result=service.append(wiki,input)
    assert_equal before,wiki.commit_for('main').parent.id
    body=wiki.page(result['path']).text_data
    assert body.index('First message')<body.index('Second message')
    assert_equal 1,result['attachments'].length
    assert_includes body,result['attachments'][0]['name']
    before=head;assert service.append(wiki,input)['unchanged'];assert_equal before,head
    assert_raises(service::Error){service.append(wiki,input.merge('text'=>'Different'))}
    error=assert_raises(service::Error){service.append(wiki,input.merge('message_id'=>'55555555-5555-4555-8555-555555555555'))}
    assert_equal 412,error.status;assert_equal before,head
    third=service.append(wiki,{'id'=>ID,'message_id'=>'66666666-6666-4666-8666-666666666666','expected_version'=>result['document_version'],'text'=>'Third message'})
    assert_includes wiki.page(third['path']).text_data,'Second message'
    assert_includes wiki.page(third['path']).text_data,'Third message'
    assert_equal 1,third['attachments'].length
  end
  def test_upload_storage_error_is_actionable
    before=head
    error=File.stub(:open,proc{raise Errno::ENOSPC}) do
      assert_raises(service::Error){upload}
    end
    assert_equal 507,error.status
    assert_includes error.message,'Server storage is full'
    assert_equal before,head
  end
  def test_chunks_checksums_and_validation_never_partial_commit
    service.upload(wiki,upload_id:UP,offset:0,data:Base64.strict_encode64('abc'))
    assert_equal 3,service.upload(wiki,upload_id:UP,offset:0,data:Base64.strict_encode64('abc'))[:next_offset]
    assert_raises(service::Error){service.upload(wiki,upload_id:UP,offset:0,data:Base64.strict_encode64('xyz'))}
    assert_raises(service::Error){service.upload(wiki,upload_id:UP,offset:9,data:'YQ==')}
    file=upload('abc');before=head
    assert_raises(service::Error){service.create(wiki,{'id'=>ID,'text'=>'test','attachments'=>[file.merge('sha256'=>'wrong')]},{})}
    assert_raises(service::Error){service.create(wiki,{'id'=>ID,'attachments'=>[file.merge('mime_type'=>'video/mp4')]},{})}
    assert_equal before,head
    assert_empty snapshot.list_raw_notes[:items]
  end
  def test_status_versions_and_local_edits
    note=service.create(wiki,{'id'=>ID,'text'=>'Test'},{})
    changed=service.status(wiki,id:ID,expected_version:note['version'],status:'processed',results:['Home.md'])
    assert_equal 'processed',changed['status']
    assert_equal ['Home.md'],changed['results']
    error=assert_raises(service::Error){service.status(wiki,id:ID,expected_version:note['version'],status:'unsorted')}
    assert_equal 412,error.status
    File.write(File.join(@dir,note['path'].sub('note.md','.note.json')),'local work')
    assert_raises(service::Error){service.status(wiki,id:ID,expected_version:changed['version'],status:'unsorted')}
  end
  def test_path_escape_read_only_and_download_private_hosts
    assert_raises(service::Error){service.upload(wiki,upload_id:'../escape',offset:0,data:'YQ==')}
    %w[https://127.0.0.1/a https://localhost/a http://example.com/a https://user:pass@example.com/a].each do |url|
      assert_raises(service::Error){service.download(wiki,{'download_url'=>url})}
    end
    ro=Gollum::Wiki.new(@dir,ref:'main',allow_editing:false)
    assert_raises(service::Error){service.create(ro,{'id'=>ID,'text'=>'No'},{})}
  end
  def test_routes_and_mcp_metadata
    body=JSON.generate(id:ID,text:'MCP note')
    assert_equal 403,@client.post('/gollum/projectbook/raw-notes/create',input:body,'CONTENT_TYPE'=>'application/json').status
    assert_equal 403,@client.post('/gollum/projectbook/raw-notes/create',input:body,'CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1','HTTP_ORIGIN'=>'https://foreign.invalid').status
    response=@client.post('/mcp',input:JSON.generate(jsonrpc:'2.0',id:1,method:'tools/list'), 'CONTENT_TYPE'=>'application/json','HTTP_ACCEPT'=>'application/json, text/event-stream')
    assert_equal 200,response.status,response.body
    tool=JSON.parse(response.body).dig('result','tools').find{|t|t['name']=='create_raw_note'}
    assert_equal ['files'],tool.dig('_meta','openai/fileParams')
    response=@client.post('/mcp',input:JSON.generate(jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'create_raw_note',arguments:{id:ID,text:'MCP note'}}),'CONTENT_TYPE'=>'application/json','HTTP_ACCEPT'=>'application/json, text/event-stream')
    assert_equal 200,response.status,response.body
    refute JSON.parse(response.body).dig('result','isError'),response.body
    assert_equal 'mcp',snapshot.read_raw_note(id:ID)['source']
  end
end
