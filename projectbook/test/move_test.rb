require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV']='test'
require 'gollum/app'

class MoveTest < Minitest::Test
  def setup
    @dir=Dir.mktmpdir('book-move-')
    system('git','init','-q','-b','main',@dir,exception:true)
    write('old/one.md',"# One\n\n[Two](sub/two.md) [Outside](../index.md) ![](image.png)\n")
    write('old/sub/two.md',"# Two\n\n[[One|../one]]\n")
    write('old/image.png',"PNG\x00\xff".b)
    write('old/.order',"[\n  \"sub\", \"image.png\", \"one.md\"\n]\n")
    write('old/sub/.order',"[\"two.md\"]\n")
    write('index.md',"# Index\n\n[One](old/one.md#oil) [Folder](/gollum/overview/old/)\n\n[[Two|old/sub/two]]\n\n`[example](old/one.md)`\n")
    write('.order',"[\"index.md\",\"old\",\"archive\"]\n")
    write('archive/.gitkeep','');write('archive/.order',"[]\n")
    Precious::App.set :gollum_path,@dir
    Precious::App.set :wiki_options,{ref:'main',allow_editing:true}
    @client=Rack::MockRequest.new(Precious::App)
  end
  def teardown;FileUtils.remove_entry(@dir);end
  def wiki;Gollum::Wiki.new(@dir,ref:'main');end
  def write(path,text);wiki.write_file(path,text,normalize:false,message:'Fixture');end
  def head;wiki.commit_for('main').id;end
  def preview(source='old',target='archive/old',**options)
    Gollum::ProjectbookMove.prepare(wiki,source:source,target:target,revision:head,**options)
  end
  def test_folder_move_preserves_internal_orders_and_binary_and_updates_links_atomically
    order=wiki.file('old/.order').raw_data; nested=wiki.file('old/sub/.order').raw_data; old=head
    plan=preview
    report=Gollum::ProjectbookMove.preview(plan)
    assert_equal old,head
    assert report[:changes].any? { |c| c[:path]=='index.md' && c[:diff].include?('archive/old/one.md#oil') }
    Gollum::ProjectbookMove.apply(wiki,plan,{})
    assert_equal old,wiki.commit_for('main').parent.id
    assert_nil wiki.file('old/one.md')
    assert_equal order,wiki.file('archive/old/.order').raw_data
    assert_equal nested,wiki.file('archive/old/sub/.order').raw_data
    assert_equal "PNG\x00\xff".b,wiki.file('archive/old/image.png').raw_data.b
    assert_includes wiki.page('archive/old/one.md').text_data,'[Outside](../../index.md)'
    assert_includes wiki.page('archive/old/one.md').text_data,'[Two](sub/two.md)'
    assert_includes wiki.page('index.md').text_data,'[[Two|archive/old/sub/two.md]]'
    assert_includes wiki.page('index.md').text_data,'`[example](old/one.md)`'
    assert_equal ['index.md','archive'],Gollum::ProjectbookTree.read_order(wiki,'')
    assert_equal ['old'],Gollum::ProjectbookTree.read_order(wiki,'archive')
    assert_equal '',Gollum::ProjectbookKnowledge.new(wiki).git('status','--porcelain')
  end
  def test_stale_preview_and_local_draft_refuse_without_partial_move
    plan=preview
    # Update existing content with the normal writer.
    page=wiki.page('index.md')
    Gollum::ProjectbookSave.save(wiki,{'path'=>'index.md','content'=>"# Changed\n",'etag'=>page.sha},[],{})
    current=head
    error=assert_raises(Gollum::ProjectbookCreation::Error){Gollum::ProjectbookMove.apply(wiki,plan,{})}
    assert_equal 412,error.status;assert_equal current,head;assert wiki.file('old/one.md')
    plan=preview
    File.write(File.join(@dir,'index.md'),'Unsaved local draft')
    error=assert_raises(Gollum::ProjectbookCreation::Error){Gollum::ProjectbookMove.apply(wiki,plan,{})}
    assert_equal 409,error.status;assert_equal current,head
  end
  def test_editor_move_includes_unsaved_content_incoming_links_and_orders
    page=wiki.page('old/one.md'); old=head
    text=page.text_data+"\nUnsaved **edit**.\n"
    result=Gollum::ProjectbookSave.save(wiki,{'source_path'=>'old/one.md','path'=>'archive/renamed.md','content'=>text,'etag'=>page.sha,'move_revision'=>old},[],{})
    assert_equal old,wiki.commit_for('main').parent.id
    assert_equal result[:commit],head
    assert_includes wiki.page('archive/renamed.md').text_data,'Unsaved **edit**.'
    assert_includes wiki.page('archive/renamed.md').text_data,'[Two](../old/sub/two.md)'
    assert_includes wiki.page('index.md').text_data,'archive/renamed.md#oil'
    refute_includes Gollum::ProjectbookTree.read_order(wiki,'old'),'one.md'
    assert_includes Gollum::ProjectbookTree.read_order(wiki,'archive'),'renamed.md'
  end
  def test_delete_removes_entry_in_same_commit
    old=head;page=wiki.page('old/one.md')
    Gollum::ProjectbookSave.delete_document(wiki,{'path'=>'old/one.md','etag'=>page.sha},{})
    assert_equal old,wiki.commit_for('main').parent.id
    assert_equal ['sub','image.png'],Gollum::ProjectbookTree.read_order(wiki,'old')
  end
  def test_move_updates_task_source_and_links_without_changing_task_identity
    list='11111111-1111-4111-8111-111111111111'; task='22222222-2222-4222-8222-222222222222'
    Gollum::ProjectbookTasks.save(wiki,[{'kind'=>'list','id'=>list,'title'=>'Review','expected_version'=>''},
      {'kind'=>'task','id'=>task,'title'=>'Check oil','list_id'=>list,'status'=>'open','source_path'=>'old/one.md','expected_version'=>''}],{})
    page=wiki.page('old/one.md')
    Gollum::ProjectbookSave.save(wiki,{'path'=>'old/one.md','content'=>page.text_data+"\n[TODO: Check oil](../.projectbook/tasks/#{task}.md)\n",'etag'=>page.sha},[],{})
    Gollum::ProjectbookMove.apply(wiki,preview,{})
    data=Gollum::ProjectbookKnowledge.new(wiki).read_todo(id:task)
    assert_equal task,data['id'];assert_equal 'archive/old/one.md',data['source_path'];assert_equal 'open',data['status']
    assert_includes wiki.page('archive/old/one.md').text_data,"../../.projectbook/tasks/#{task}.md"
    assert_equal ['archive/old/one.md'],Gollum::ProjectbookTasks.source_references(Gollum::ProjectbookKnowledge.new(wiki))[task]
  end
  def test_missing_preview_revision_refuses_editor_move
    page=wiki.page('old/one.md');old=head
    error=assert_raises(Gollum::ProjectbookCreation::Error){Gollum::ProjectbookSave.save(wiki,{'path'=>'archive/new.md','source_path'=>'old/one.md','content'=>page.text_data,'etag'=>page.sha},[],{})}
    assert_equal 412,error.status;assert_equal old,head
  end
  def test_rename_keeps_the_same_position_in_manual_order
    Gollum::ProjectbookMove.apply(wiki,preview('old/one.md','old/renamed.md'),{})
    assert_equal ['sub','image.png','renamed.md'],Gollum::ProjectbookTree.read_order(wiki,'old')
  end
  def test_legacy_attachment_delete_also_removes_order_entry
    old=head
    reply=@client.post('/gollum/delete/old/image.png')
    assert_equal 200,reply.status,reply.body
    assert_nil wiki.file('old/image.png')
    assert_equal ['sub','one.md'],Gollum::ProjectbookTree.read_order(wiki,'old')
    assert_equal old,wiki.commit_for('main').parent.id
  end
  def test_rejects_descendants_collisions_hidden_targets_and_symlinks
    ['old/sub/new','.projectbook/old','archive/.hidden'].each do |target|
      assert_raises(Gollum::ProjectbookCreation::Error){preview('old',target)}
    end
    assert_raises(Gollum::ProjectbookCreation::Error){preview('old','archive')}
    File.symlink('/tmp',File.join(@dir,'old/link'))
    system('git','-C',@dir,'add','old/link',exception:true)
    system('git','-C',@dir,'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','Symlink',exception:true)
    assert_raises(Gollum::ProjectbookCreation::Error){preview}
  end
  def test_http_preview_has_no_writes_and_is_origin_protected
    old=head
    headers={'CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1',input:JSON.generate(source:'old',target:'archive/old',revision:old)}
    reply=@client.post('/gollum/projectbook/move/preview',headers)
    assert_equal 200,reply.status,reply.body;assert_equal old,head
    assert_equal 403,@client.post('/gollum/projectbook/move/preview',headers.merge('HTTP_ORIGIN'=>'https://elsewhere.invalid')).status
  end
end
