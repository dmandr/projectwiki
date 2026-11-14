require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
ENV['APP_ENV']='test'
require 'gollum/app'
require 'gollum/projectbook_inline_todo_migration'
class InlineTodosTest < Minitest::Test
  def setup
    @dir=Dir.mktmpdir('inline-todos-')
    system('git','init','-q','-b','main',@dir,exception:true)
    wiki.write_page('Home',:markdown,"# Home\n\n[TODO: Масло]() and [todo: Масло](tags=engine)\n",message:'Fixture')
  end
  def teardown;FileUtils.remove_entry(@dir);end
  def wiki;Gollum::Wiki.new(@dir,ref:'main');end
  def snapshot;Gollum::ProjectbookKnowledge.new(wiki);end
  def tasks;Gollum::ProjectbookInlineTodos.catalog(snapshot)[:tasks];end
  def change(task,values={});task.slice('path','start','title','done','tags').merge('expected_version'=>task['version']).merge(values);end
  def test_duplicate_text_is_independent_and_utf8_offsets_are_correct
    before=wiki.commit_for('main').id;items=tasks
    assert_equal 2,items.size
    assert_equal 'Масло',items[0]['title']
    result=Gollum::ProjectbookInlineTodos.save(wiki,[change(items[1],{'done'=>'2026-11-03T11:22','tags'=>['engine','весна']})],{message:'Complete one'})
    assert_equal before,wiki.commit_for('main').parent.id
    assert_empty tasks[0]['done'];refute_empty tasks[1]['done']
    assert_includes wiki.page('Home.md').text_data,'[TODO: Масло]() and '
    assert_empty snapshot.entries.select { |e| e[:path].include?('.projectbook/tasks/') }
    assert result[:commit]
  end
  def test_stale_location_does_not_modify_another_task
    item=tasks[0]
    Gollum::ProjectbookInlineTodos.save(wiki,[change(item,{'title'=>'Changed'})],{message:'Change'})
    head=wiki.commit_for('main').id
    error=assert_raises(Gollum::ProjectbookCreation::Error) { Gollum::ProjectbookInlineTodos.save(wiki,[change(item,{'done'=>'2026-11-03T11:22'})],{message:'Stale'}) }
    assert_equal 412,error.status;assert_equal head,wiki.commit_for('main').id
  end
  def test_bulk_changes_are_atomic_and_ignore_code_examples
    wiki.write_page('Examples',:markdown,"# Examples\n\n`[TODO: Example]()`\n\n```md\n[TODO: code]()\n```\n",message:'Examples')
    assert_equal 2,tasks.size
    items=tasks
    Gollum::ProjectbookInlineTodos.save(wiki,items.map { |t| change(t,{'tags'=>['spring']}) },{message:'Tags'})
    assert tasks.all? { |t| t['tags']==['spring'] }
    revision=wiki.commit_for('main').id
    preview=Gollum::ProjectbookInlineTodos.save(wiki,[change(tasks[0],{'title'=>'Preview'})],{message:'Preview'},dry_run:true)
    refute preview[:changes].empty?;assert_equal revision,wiki.commit_for('main').id
  end
  def test_mcp_writes_source_and_rejects_stale_versions
    item=snapshot.list_tasks[:items].first
    result=snapshot.save_todos(changes:[change(item,{'title'=>'MCP text','tags'=>['boat']})],dry_run:false)
    assert result[:commit]
    assert_equal 'MCP text',snapshot.read_todo(path:item['path'],start:item['start'])['title']
    error=assert_raises(Gollum::ProjectbookCreation::Error) { snapshot.save_todos(changes:[change(item)],dry_run:false) }
    assert_equal 412,error.status
  end
  def test_http_permissions_and_version_checks
    require 'rack/mock'
    Precious::App.set :gollum_path,@dir
    Precious::App.set :wiki_options,{ref:'main',allow_editing:true,allow_uploads:true}
    client=Rack::MockRequest.new(Precious::App)
    body=JSON.generate(changes:[change(tasks.first,{'tags'=>['api']})])
    url='/gollum/projectbook/inline-todos'
    assert_equal 403,client.post(url,input:body,'CONTENT_TYPE'=>'application/json').status
    headers={'CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1'}
    assert_equal 403,client.post(url,headers.merge(input:body,'HTTP_ORIGIN'=>'https://foreign.test')).status
    reply=client.post(url,headers.merge(input:body))
    assert_equal 200,reply.status,reply.body
    assert_equal wiki.page('Home.md').sha,JSON.parse(reply.body)['versions']['Home.md']
    assert_equal 412,client.post(url,headers.merge(input:body)).status
    Precious::App.set :wiki_options,{ref:'main',allow_editing:false}
    assert_equal 403,client.post(url,headers.merge(input:body)).status
  end
  def test_migration_preserves_orphans_metadata_queries_and_is_idempotent
    list='11111111-1111-4111-8111-111111111111';task='22222222-2222-4222-8222-222222222222';orphan='33333333-3333-4333-8333-333333333333'
    changes=[{'kind'=>'list','id'=>list,'title'=>'Весна','expected_version'=>''}]
    [task,orphan].each { |id| changes<<{'kind'=>'task','id'=>id,'title'=>'Oil','list_id'=>list,'status'=>'done','notes'=>'Do not lose this','expected_version'=>''} }
    Gollum::ProjectbookTasks.save(wiki,changes,{message:'Legacy'})
    wiki.write_page('Old',:markdown,"# Old\n\n[TODO: stale](.projectbook/tasks/#{task}.md)\n\n[TODO list: Весна](.projectbook/task-lists/#{list}.md)\n",message:'Legacy references')
    preview=Gollum::ProjectbookInlineTodoMigration.run(wiki)
    assert_equal 3,preview[:remove].size
    result=Gollum::ProjectbookInlineTodoMigration.run(wiki,dry_run:false)
    assert result[:commit]
    text=wiki.page('Old.md').text_data
    assert_includes text,'[TODO: Oil](done=';assert_includes text,':::todos'
    assert_includes wiki.page('todo-migration-recovered.md').text_data,'Do not lose this'
    assert_equal 4,tasks.size
    assert_empty snapshot.entries.select { |e| Gollum::ProjectbookTasks.identity(e[:path]) }
    assert_empty Gollum::ProjectbookInlineTodoMigration.run(wiki,dry_run:false)[:remove]
  end
end
