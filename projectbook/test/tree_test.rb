require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV'] = 'test'
require 'gollum/app'
require_relative '../extensions/document_tree'

class TreeTest < Minitest::Test
  def setup
    @dir=Dir.mktmpdir('projectbook-tree-')
    system('git','init','-q','-b','main',@dir,exception:true)
    wiki.write_file('a/first.md',"# First\n",message:'Fixture')
    wiki.write_file('a/second.md',"# Second\n",message:'Fixture')
    wiki.write_file('b/.gitkeep','',message:'Fixture')
    Precious::App.set :gollum_path,@dir
    Precious::App.set :wiki_options,{ref:'main',allow_editing:true}
    @client=Rack::MockRequest.new(Precious::App)
  end
  def teardown;FileUtils.remove_entry(@dir);end
  def test_folder_overview_opens_editable_index_and_explicit_listing_remains_available
    wiki.write_file('a/.index.md', "# Folder title\n\n[First](first.md)\n", message:'Landing')
    response=@client.get('/gollum/overview/a/')
    assert_equal 302,response.status
    assert_equal '/a/.index.md',URI(response['Location']).path
    listing=@client.get('/gollum/overview/a/?files=1')
    assert_equal 200,listing.status
    assert_includes listing.body,'first.md'
    assert_equal 200,@client.get('/gollum/overview/b/').status
    page=wiki.page('a/.index.md')
    wiki.delete_page(page,message:'Remove landing')
    assert_equal 200,@client.get('/gollum/overview/a/').status
  end
  def wiki;Gollum::Wiki.new(@dir,ref:'main');end
  def revision;wiki.commit_for('main').id;end
  def post(input, headers={})
    @client.post('/gollum/projectbook/tree',{'CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1',input:JSON.generate({revision:revision}.merge(input))}.merge(headers))
  end
  def order(folder);Gollum::ProjectbookTree.read_order(wiki,folder);end
  def test_reorder_is_hidden_tree_only_and_new_items_append
    old=revision
    reply=post(action:'reorder',source:'a/second.md',folder:'a',before:'first.md')
    assert_equal 200,reply.status,reply.body
    assert_equal ['second.md','first.md'],order('a')
    assert_equal old,wiki.commit_for('main').parent.id
    refute Gollum::NavigationIndex.for(wiki).entries.any? { |e| e.name == '.order' }
    assert_equal "# First\n",wiki.page('a/first.md').text_data
    Gollum::ProjectbookSave.save(wiki,{'create'=>true,'path'=>'a/aaa.md','content'=>"# New\n"},[],{message:'New'})
    assert_equal ['second.md','first.md','aaa.md'],order('a')
    Gollum::ProjectbookSave.save(wiki,{'create'=>true,'path'=>'b/new.md','content'=>"# New\n"},[],{message:'New'})
    refute wiki.file('b/.order')
    view=Object.new.extend(ProjectBookDocumentTree)
    def view.base_url;'';end
    html=view.projectbook_tree_html
    assert_operator html.index('data-document="a/second.md"'),:<,html.index('data-document="a/first.md"')
    assert_operator html.index('data-document="a/first.md"'),:<,html.index('data-document="a/aaa.md"')
  end
  def test_move_and_orders_are_one_commit_with_version_checks
    post(action:'reorder',source:'a/second.md',folder:'a',before:'first.md')
    old=revision
    page=wiki.page('a/second.md')
    reply=post(action:'move',source:'a/second.md',folder:'b',content:page.text_data,etag:page.sha)
    assert_equal 200,reply.status,reply.body
    assert_equal old,wiki.commit_for('main').parent.id
    refute wiki.page('a/second.md')
    assert_equal "# Second\n",wiki.page('b/second.md').text_data
    assert_equal ['first.md'],order('a')
    assert_equal 412,post(action:'reorder',source:'a/first.md',folder:'a',before:nil,revision:old).status
  end
  def test_rejects_local_edits_collisions_hidden_paths_and_csrf
    page=wiki.page('a/first.md')
    assert_equal 403,post({action:'reorder'},'HTTP_ORIGIN'=>'https://evil.example').status
    assert_equal 422,post(action:'reorder',source:'a/.order',folder:'a').status
    assert_equal 422,post(action:'move',source:'a/first.md',folder:'.projectbook',content:page.text_data,etag:page.sha).status
    wiki.write_file('b/first.md',"# Existing\n",message:'Fixture')
    assert_equal 409,post(action:'move',source:'a/first.md',folder:'b',content:page.text_data,etag:page.sha).status
    File.write(File.join(@dir,'a/first.md'),'Local draft')
    assert_equal 409,post(action:'reorder',source:'a/second.md',folder:'a',before:'first.md').status
  end
  def test_binary_move_keeps_bytes_and_empty_folder
    bytes="PDF\x00\xff".b
    wiki.write_file('media/file.pdf',bytes,message:'Fixture')
    sha=Gollum::ProjectbookKnowledge.new(wiki).entries.find { |e| e[:path]=='media/file.pdf' }[:sha]
    reply=post(action:'move',source:'media/file.pdf',folder:'b',etag:sha)
    assert_equal 200,reply.status,reply.body
    assert_equal bytes,wiki.file('b/file.pdf').raw_data.b
    refute wiki.file('media/file.pdf')
    assert wiki.file('media/.gitkeep')
  end
  def test_noop_does_not_commit_and_folder_ordering_is_allowed
    old=revision
    assert_equal 200,post(action:'reorder',source:'a/second.md',folder:'a',before:nil).status
    assert_equal old,revision
    refute wiki.file('a/.order')
    assert_equal 200,post(action:'reorder',source:'b',folder:'',before:'a').status
    assert_equal ['b','a'],order('')
  end
end
