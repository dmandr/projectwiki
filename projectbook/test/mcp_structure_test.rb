require_relative 'mcp_test'

class ProjectbookMCPStructureTest < ProjectbookMCPTest
  # The base suite remains in mcp_test.rb; these methods exercise the new protocol surface.
  def test_move_preview_apply_updates_links_and_task_sources
    page=wiki.page('Home')
    Gollum::ProjectbookSave.save(wiki,{'path'=>'Home.md','content'=>"# Home\n\n[Engine](hardware/engine.md)\n",'etag'=>page.sha},[],{})
    list='11111111-1111-4111-8111-111111111111'; task='22222222-2222-4222-8222-222222222222'
    Gollum::ProjectbookTasks.save(wiki,[{'kind'=>'list','id'=>list,'title'=>'Work','expected_version'=>''},
      {'kind'=>'task','id'=>task,'title'=>'Check','list_id'=>list,'status'=>'open','source_path'=>'hardware/engine.md','expected_version'=>''}],{})
    rev=head
    args={source:'hardware',target:'current/hardware',expected_revision:rev}
    preview,error=tool('move_document',args);refute error;assert preview['dry_run'];assert_equal rev,head
    assert preview['changes'].any?{|c|c['path']=='Home.md' && c['diff'].include?('current/hardware/engine.md')}
    saved,error=tool('move_document',args.merge(dry_run:false));refute error
    assert_equal rev,wiki.commit_for('main').parent.id
    assert_equal saved['revision'],head
    assert_nil wiki.page('hardware/engine.md')
    assert_includes wiki.page('Home.md').text_data,'current/hardware/engine.md'
    data,=tool('read_todo',{id:task});assert_equal 'current/hardware/engine.md',data['source_path'];assert_equal 'open',data['status']
    _,error=tool('move_document',args.merge(dry_run:false));assert error;assert_equal saved['revision'],head
  end

  def test_rename_checks_source_version_and_does_not_overwrite
    rev=head;sha=wiki.page('hardware/engine.md').sha
    args={source:'hardware/engine.md',target:'hardware/motor.md',expected_revision:rev,expected_version:'0'*40}
    _,error=tool('move_document',args.merge(dry_run:false));assert error;assert_equal rev,head
    _,error=tool('move_document',args.merge(expected_version:sha,target:'Home.md',dry_run:false));assert error;assert_equal rev,head
    result,error=tool('move_document',args.merge(expected_version:sha,dry_run:false));refute error
    assert wiki.page('hardware/motor.md');assert_nil wiki.page('hardware/engine.md');assert_equal result['revision'],head
  end

  def test_reorder_preview_apply_noop_and_stale_revision
    view,error=tool('get_tree_order');refute error;assert_equal ['hardware','Home.md'],view['order']
    args={source:'Home.md',before:'hardware',expected_revision:head};old=head
    preview,error=tool('reorder_tree',args);refute error;assert preview['dry_run'];assert_equal old,head
    assert_equal ['Home.md','hardware'],preview['order']
    result,error=tool('reorder_tree',args.merge(dry_run:false));refute error;assert_equal result['revision'],head
    view,=tool('get_tree_order');assert_equal ['Home.md','hardware'],view['order']
    assert_equal view['order'],view['manual_order']
    _,error=tool('reorder_tree',args.merge(dry_run:false));assert error
    saved=head
    noop,error=tool('reorder_tree',args.merge(expected_revision:saved,dry_run:false));refute error;assert noop['unchanged'];assert_equal saved,head
    oldview,=tool('get_tree_order',{revision:old});assert_equal ['hardware','Home.md'],oldview['order']
  end

  def test_tree_operations_reject_dirty_paths_and_invalid_siblings
    rev=head
    [['hardware','hardware/sub'],['hardware','../escape'],['.projectbook','public'],['raw-notes','archive'],['hardware','raw-notes/new']].each do |source,target|
      _,error=tool('move_document',{source:source,target:target,expected_revision:rev,dry_run:false});assert error
    end
    _,error=tool('reorder_tree',{source:'Home.md',before:'missing.md',expected_revision:rev});assert error
    _,error=tool('get_tree_order',{path:'../'});assert error
    File.write(File.join(@dir,'Home.md'),'Unsaved work')
    _,error=tool('move_document',{source:'hardware',target:'archive',expected_revision:rev,dry_run:false});assert error
    _,error=tool('reorder_tree',{source:'Home.md',expected_revision:rev,dry_run:false});assert error
    assert_equal rev,head;assert_equal 'Unsaved work',File.read(File.join(@dir,'Home.md'))
  end

  def test_move_folder_index_preserves_attachment_and_blocks_stale_preview
    wiki.write_file('hardware/.index.md',"# Hardware\n",normalize:false,message:'Folder title')
    wiki.write_file('hardware/manual.pdf',"%PDF-test\x00\xff".b,normalize:false,message:'Attachment')
    rev=head;sha=wiki.page('hardware/.index.md').sha
    args={source:'hardware/.index.md',target:'boat/.index.md',expected_revision:rev,expected_version:sha}
    _,error=tool('move_document',args);refute error
    saved,error=tool('move_document',args.merge(dry_run:false));refute error
    assert_equal '/boat/.index.md',saved['url']
    assert_equal "%PDF-test\x00\xff".b,wiki.file('boat/manual.pdf').raw_data.b
    assert_equal sha,wiki.page('boat/.index.md').sha
    assert_equal '',Gollum::ProjectbookKnowledge.new(wiki).git('status','--porcelain')
  end

  def test_structure_discovery_respects_write_gate_and_annotations
    list=JSON.parse(rpc('tools/list').body).dig('result','tools')
    %w[move_document reorder_tree].each do |name|
      t=list.find{|item|item['name']==name};refute_nil t
      assert t.dig('annotations','destructiveHint');refute t.dig('annotations','readOnlyHint')
      refute t['inputSchema']['properties'].key?('revision')
    end
    ENV['PROJECTBOOK_MCP_DOCUMENT_WRITE']='false'
    list=JSON.parse(rpc('tools/list').body).dig('result','tools')
    refute list.any?{|t|%w[move_document reorder_tree].include?(t['name'])}
    assert list.any?{|t|t['name']=='get_tree_order'}
  end
end
