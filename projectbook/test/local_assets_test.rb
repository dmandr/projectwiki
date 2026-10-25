require_relative 'editor_save_test'
class LocalAssetsTest < EditorSaveTest
  def asset;@target.sub('uploads/','.asset/');end
  def test_shared_move_copy_delete_and_clipboard
    assert_equal 200,save(payload).status
    service=Gollum::ProjectbookLocalAssets;snap=Gollum::ProjectbookKnowledge.new(wiki)
    refute snap.visible?(snap.entries.find { |e|e[:path]==asset })
    assert_equal "%PDF-1.4\x00\xff".b,Base64.decode64(snap.read_attachment(path:asset,format:'bytes')[:data])
    service.copy(wiki,source:'Home.md',target:'Copies/new.md',revision:head,dry_run:false)
    assert_includes wiki.page('Copies/new.md').text_data,'/'+asset
    plan=Gollum::ProjectbookMove.prepare(wiki,source:'Home.md',target:'nested/Moved.md',revision:head)
    Gollum::ProjectbookMove.apply(wiki,plan,{})
    assert_includes wiki.page('nested/Moved.md').text_data,'/'+asset
    Gollum::ProjectbookSave.delete_document(wiki,{'path'=>'nested/Moved.md','etag'=>wiki.page('nested/Moved.md').sha},{})
    assert wiki.file(asset)
    result=service.paste(wiki,"[PDF](../#{asset})\n<img src=\"/#{asset}\" width=\"23%\" />\n`![example](#{asset})`",'Other/deep.md')
    assert_empty result[:attachments]
    assert_includes result[:content],"[PDF](/#{asset})"
    assert_includes result[:content],'width="23%"'
    assert_includes result[:content],"`![example](#{asset})`"
  end
  def test_hidden_files_security
    assert_equal 200,save(payload).status
    response=@client.get('/'+asset)
    assert_equal 200,response.status,response.body
    assert_equal 'nosniff',response['x-content-type-options']
    snap=Gollum::ProjectbookKnowledge.new(wiki)
    ['.git/config','.asset/../config','.asset/not-uuid/file.png'].each do |p|
      assert_raises(Gollum::ProjectbookCreation::Error) { snap.read_attachment(path:p) }
    end
  end
  def test_mcp_upload_preview_apply
    upload_id='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';bytes='test pdf'
    w=Gollum::Wiki.new(@dir,ref:'main',allow_uploads:true)
    Gollum::ProjectbookRawNotes.upload(w,upload_id:upload_id,offset:0,data:Base64.strict_encode64(bytes))
    snap=Gollum::ProjectbookKnowledge.new(w)
    args={path:'PDF.md',content:"# PDF\n[File](uploads/#{upload_id}/file.pdf)",expected_version:'',attachments:[{upload_id:upload_id,name:'file.pdf',sha256:Digest::SHA256.hexdigest(bytes)}]}
    before=head;snap.save_document(**args,dry_run:true);assert_equal before,head
    result=snap.save_document(**args,dry_run:false)
    assert_equal wiki.page('PDF.md').sha,result[:version]
    assert_equal bytes,wiki.file('.asset/'+upload_id+'/file.pdf').raw_data
  end
end
