require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV']='test'
require 'gollum/app'
require_relative '../extensions/document_tree'
class FolderPagesTest < Minitest::Test
  def setup
    @dir=Dir.mktmpdir
    system('git','init','-q','-b','main',@dir,exception:true)
    wiki.write_page('Home',:markdown,"# Home\n",message:'Fixture')
    Precious::App.set :gollum_path,@dir
    Precious::App.set :wiki_options,{ref:'main',allow_editing:true,h1_title:true}
    @client=Rack::MockRequest.new(Precious::App)
  end
  def teardown;FileUtils.remove_entry(@dir);end
  def wiki;Gollum::Wiki.new(@dir,ref:'main');end
  def head;wiki.commit_for('main').id;end
  def write(path,text);wiki.write_file(path,text,message:'Fixture');end
  def create(folder='engine',title='Engine overview');Gollum::ProjectbookFolders.create(wiki,folder:folder,title:title);end
  def post(path,input);@client.post(path,input:JSON.generate(input),'CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1');end
  def test_create_title_index_hidden_and_empty_block
    before=head;create
    assert_equal before,wiki.commit_for('main').parent.id
    page=wiki.page('engine/.index.md')
    assert_includes page.text_data,'# Engine overview'
    assert_includes page.text_data,'[Pages](#projectbook-pages)'
    assert_equal 'Engine',Gollum::ProjectbookTitles.from_path('engine/.index.md')
    assert_equal 'Engine overview',Gollum::NavigationIndex.for(wiki).folder_page('engine').title
    html=Object.new.extend(ProjectBookDocumentTree)
    def html.base_url;'';end
    refute_includes html.projectbook_tree_html,'data-document="engine/.index.md"'
    assert_includes html.projectbook_tree_html,'Engine overview'
    response=@client.get('/engine/.index.md')
    assert_equal 200,response.status,response.body
    refute_includes response.body,'class="pb-subpages"'
    assert_equal 302,@client.get('/gollum/overview/engine/').status
    assert_equal 200,@client.get('/gollum/projectbook/tree/document?path=engine/.index.md').status
    refute_includes @client.get('/gollum/overview/engine/?files=1').body,'href="/engine/.index.md"'
  end
  def test_dynamic_block_order_and_removal_and_code_sample
    create;write('engine/a.md',"# First\n");write('engine/z.md',"# Last\n");write('engine/.order',JSON.generate(['z.md','a.md']))
    html=@client.get('/engine/.index.md').body
    assert_includes html,'class="pb-subpages"'
    assert html.index('href="/engine/z.md"') < html.index('href="/engine/a.md"')
    page=wiki.page('engine/.index.md')
    Gollum::ProjectbookSave.save(wiki,{'path'=>page.url_path,'etag'=>page.sha,'content'=>"# Only title\n"},[],{message:'Remove block'})
    refute_includes @client.get('/engine/.index.md').body,'class="pb-subpages"'
    assert wiki.page('engine/a.md')
    html=Gollum::ProjectbookFolders.render('<pre><code>[Pages](#projectbook-pages)</code></pre>',wiki.page('engine/.index.md'))
    assert_includes html,'<code>'
    refute_includes html,'class="pb-subpages"'
  end
  def test_existing_folder_read_does_not_write_and_explicit_create
    write('old/item.md',"# Existing\n");before=head
    response=@client.get('/gollum/overview/old/')
    assert_equal 200,response.status
    assert_includes response.body,'Create folder page'
    assert_equal before,head
    response=post('/gollum/projectbook/folder-page',{folder:'old',title:'Old folder'})
    assert_equal 200,response.status,response.body
    assert wiki.page('old/.index.md')
    assert_equal 409,post('/gollum/projectbook/folder-page',{folder:'old',title:'Overwrite'}).status
  end
  def test_reserved_names_and_mcp_edit
    ['.index.md','x/.secret.md','.private/.index.md','x/../.index.md'].each { |path| assert_raises(Gollum::ProjectbookCreation::Error){Gollum::ProjectbookSave.path!(path)} }
    create
    snapshot=Gollum::ProjectbookKnowledge.new(wiki)
    assert snapshot.docs.any? { |e| e[:path]=='engine/.index.md' }
    data=snapshot.read_document(path:'engine/.index.md')
    snapshot.edit_document(path:'engine/.index.md',expected_version:data[:sha],edits:[{old_text:'# Engine overview',new_text:'# New title'}],dry_run:false)
    assert_equal 'New title',Gollum::NavigationIndex.for(wiki).folder_page('engine').title
  end
  def test_move_folder_from_page_preserves_children_order_and_incoming_links
    create;write('engine/child.md',"# Child\n");write('engine/.order',"[\"child.md\"]\n")
    write('ref.md',"# Ref\n\n[Engine](engine/.index.md#anchor)\n")
    page=wiki.page('engine/.index.md');revision=head
    input={'source_path'=>page.url_path,'path'=>'systems/power/.index.md','etag'=>page.sha,'move_revision'=>revision,'content'=>"# Changed title\n\n[Child](child.md)\n"}
    Gollum::ProjectbookSave.save(wiki,input,[],{message:'Move folder'})
    assert_equal revision,wiki.commit_for('main').parent.id
    assert wiki.page('systems/power/child.md')
    assert_equal "[\"child.md\"]\n",wiki.file('systems/power/.order').raw_data
    assert_includes wiki.page('systems/power/.index.md').text_data,'Changed title'
    assert_includes wiki.page('ref.md').text_data,'systems/power/.index.md#anchor'
    refute wiki.page('engine/.index.md')
  end
  def test_delete_requires_confirmation_revision_and_removes_whole_subtree_order
    create;write('engine/sub/item.md',"# Nested\n");write('engine/media/a.bin','binary');write('.order',JSON.generate(['engine','Home.md']))
    preview=Gollum::ProjectbookFolders.delete_preview(wiki,'engine');before=head
    assert_equal 3,preview[:files]
    assert_raises(Gollum::ProjectbookCreation::Error){Gollum::ProjectbookFolders.delete(wiki,folder:'engine',revision:before,confirmed_folder:nil)}
    assert_equal before,head
    assert_raises(Gollum::ProjectbookCreation::Error){Gollum::ProjectbookSave.delete_document(wiki,{'path'=>'engine/.index.md','etag'=>wiki.page('engine/.index.md').sha},{})}
    assert_equal 422,@client.post('/gollum/delete/engine/.index.md').status
    write('other.md',"# Other\n")
    assert_raises(Gollum::ProjectbookCreation::Error){Gollum::ProjectbookFolders.delete(wiki,folder:'engine',revision:before,confirmed_folder:'engine')}
    before=head
    Gollum::ProjectbookFolders.delete(wiki,folder:'engine',revision:before,confirmed_folder:'engine')
    assert_equal before,wiki.commit_for('main').parent.id
    assert_empty Gollum::ProjectbookKnowledge.new(wiki).entries.select { |e| e[:path].start_with?('engine/') }
    refute_includes Gollum::ProjectbookTree.read_order(wiki,''),'engine'
    assert_raises(Gollum::ProjectbookCreation::Error){Gollum::ProjectbookFolders.delete_preview(wiki,'')}
  end

  def test_delete_http_returns_existing_parent_overview
    create
    response=post('/gollum/projectbook/folder-delete/confirm',
      {folder:'engine',revision:head,confirmed_folder:'engine'})
    assert_equal 200,response.status,response.body
    target=JSON.parse(response.body).fetch('url')
    assert_equal '/gollum/overview',target
    assert_equal 200,@client.get(target).status

    create('systems/engine')
    write('systems/other.md',"# Other\n")
    response=post('/gollum/projectbook/folder-delete/confirm',
      {folder:'systems/engine',revision:head,confirmed_folder:'systems/engine'})
    assert_equal 200,response.status,response.body
    target=JSON.parse(response.body).fetch('url')
    assert_equal '/gollum/overview/systems/',target
    assert_equal 200,@client.get(target).status
  end
end
