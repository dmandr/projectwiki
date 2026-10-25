require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV'] = 'test'
require 'gollum/app'

class DeleteDocumentTest < Minitest::Test
  def setup
    @dir=Dir.mktmpdir('projectbook-delete-')
    system('git','init','-q','-b','main',@dir,exception:true)
    wiki.write_page('Home',:markdown,"# Home\n",message:'Fixture')
    wiki.write_page('Delete me',:markdown,"# Delete me\n",message:'Fixture')
    Precious::App.set :gollum_path,@dir
    Precious::App.set :wiki_options,{ref:'main',allow_editing:true}
    @client=Rack::MockRequest.new(Precious::App)
    @etag=wiki.page('Delete me.md').sha
  end
  def teardown;FileUtils.remove_entry(@dir);end
  def wiki;Gollum::Wiki.new(@dir,ref:'main');end
  def request(etag=@etag,headers={})
    @client.post('/gollum/projectbook/delete',{'CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1',input:JSON.generate(path:'Delete me.md',etag:etag)}.merge(headers))
  end
  def test_delete_is_a_git_commit_and_keeps_old_content
    before=wiki.commit_for('main').id
    reply=request
    assert_equal 200,reply.status,reply.body
    refute wiki.page('Delete me.md')
    assert_equal before,wiki.commit_for('main').parent.id
    assert_equal "# Delete me\n",Gollum::ProjectbookKnowledge.new(wiki,revision:before).read_document(path:'Delete me.md')[:content]
    assert_equal '/gollum/overview',JSON.parse(reply.body)['url']
  end
  def test_stale_and_local_edits_block_delete
    assert_equal 412,request('0'*40).status
    assert wiki.page('Delete me.md')
    File.write(File.join(@dir,'Delete me.md'),'Uncommitted changes')
    assert_equal 409,request.status
    assert wiki.page('Delete me.md')
  end
  def test_permissions_and_missing_page
    assert_equal 403,request(@etag,{'HTTP_X_PROJECTWIKI_REQUEST'=>nil}).status
    assert_equal 403,request(@etag,{'HTTP_ORIGIN'=>'https://elsewhere.test'}).status
    Precious::App.set :wiki_options,{ref:'main',allow_editing:false}
    assert_equal 403,request.status
    Precious::App.set :wiki_options,{ref:'main',allow_editing:true}
    assert_equal 200,request.status
    assert_equal 404,request.status
  end
end
