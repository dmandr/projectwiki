require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rack/mock'
ENV['APP_ENV'] = 'test'
require 'gollum/app'
require 'gollum/projectbook_task_migration'

class TasksTest < Minitest::Test
  LIST = '11111111-1111-4111-8111-111111111111'
  TASK = '22222222-2222-4222-8222-222222222222'
  def setup
    @dir=Dir.mktmpdir('projectbook-tasks-')
    system('git','init','-q','-b','main',@dir,exception:true)
    wiki.write_page('Home',:markdown,"# Home\n",message:'Fixture')
    Precious::App.set :gollum_path,@dir
    Precious::App.set :wiki_options,{ref:'main',allow_editing:true,allow_uploads:true}
    @client=Rack::MockRequest.new(Precious::App)
  end
  def teardown;FileUtils.remove_entry(@dir);end
  def wiki;Gollum::Wiki.new(@dir,ref:'main');end
  def head;wiki.commit_for('main').id;end
  def list;{'kind'=>'list','id'=>LIST,'title'=>'Весна','notes'=>'Annual preparation','expected_version'=>''};end
  def task;{'kind'=>'task','id'=>TASK,'title'=>'Проверить масло','notes'=>'Read the manual','list_id'=>LIST,'status'=>'open','due'=>'2027-04-01','expected_version'=>''};end
  def service;Gollum::ProjectbookKnowledge.new(wiki);end
  def write(changes,dry_run:false);service.save_todos(changes:changes,dry_run:dry_run);end
  def current_task
    item=service.read_todo(id:TASK)
    item.transform_keys(&:to_s).merge('expected_version'=>item[:version])
  end
  def test_lists_tasks_and_dry_run_are_one_commit
    before=head
    preview=write([list,task],dry_run:true)
    assert_equal 2,preview[:changes].length
    assert_equal before,head
    write([list,task])
    assert_equal before,wiki.commit_for('main').parent.id
    assert_equal 'Весна',service.list_todo_lists[:items][0]['title']
    assert_equal 1,service.list_tasks(list_id:LIST,status:'open')[:items].length
    assert_equal task['title'],service.read_todo(id:TASK)['title']
    assert File.read(File.join(@dir,".projectbook/tasks/#{TASK}.md")).start_with?('# ')
    revision=head
    write([current_task])
    assert_equal revision,head,'Unchanged metadata must not create a commit'
  end
  def test_document_and_tasks_atomic_conflict_and_snapshot
    before=head
    source=wiki.page('Home.md')
    input={'path'=>'Home.md','etag'=>source.sha,'content'=>"# Home\n\n[TODO: Oil](Tasks/#{TASK}.md)\n",'todos'=>[list,task]}
    Gollum::ProjectbookSave.save(wiki,input,[],{message:'Document with TODO'})
    created=head
    assert_equal before,wiki.commit_for('main').parent.id
    old=current_task
    write([old.merge('status'=>'done')])
    input.merge!('etag'=>wiki.page('Home.md').sha,'content'=>"# Home\n\nMust not save\n",'todos'=>[old.merge('title'=>'Stale edit')])
    last=head
    error=assert_raises(Gollum::ProjectbookCreation::Error){Gollum::ProjectbookSave.save(wiki,input,[],{message:'Stale'})}
    assert_equal 412,error.status
    assert_equal last,head
    refute_includes wiki.page('Home.md').text_data,'Must not save'
    assert_equal 'open',Gollum::ProjectbookKnowledge.new(wiki,revision:created).read_todo(id:TASK)['status']
    assert_equal 'done',service.read_todo(id:TASK)['status']
  end
  def test_invalid_metadata_duplicates_local_work_and_unknown_lists
    before=head
    [task.merge('id'=>'../escape'),task.merge('status'=>'unknown'),task.merge('due'=>'2026-02-30'),task.merge('list_id'=>'')].each do |bad|
      assert_raises(Gollum::ProjectbookCreation::Error){write([list,bad])}
      assert_equal before,head
    end
    assert_raises(Gollum::ProjectbookCreation::Error){write([task])}
    assert_raises(Gollum::ProjectbookCreation::Error){write([list,list.merge('id'=>TASK)])}
    write([list,task]);before=head
    File.write(File.join(@dir,".projectbook/tasks/#{TASK}.md"),'Local work')
    assert_raises(Gollum::ProjectbookCreation::Error){write([current_task.merge('status'=>'done')])}
    assert_equal before,head
  end
  def test_title_notes_roundtrip_and_list_rename
    write([list,task.merge('title'=>'Oil & [filter] *check*','notes'=>"Hello\n\n```ruby\nputs 1\n```\n")])
    assert_equal 'Oil & [filter] *check*',service.read_todo(id:TASK)['title']
    item=service.read_todo(id:LIST,kind:'list')
    write([item.transform_keys(&:to_s).merge('title'=>'Autumn','expected_version'=>item[:version])])
    assert_equal LIST,service.read_todo(id:TASK)['list_id']
    assert_equal 'Autumn',service.list_todo_lists[:items][0]['title']
  end
  def test_api_permissions_and_catalog
    body=JSON.generate(changes:[list,task])
    assert_equal 403,@client.post('/gollum/projectbook/tasks',input:body,'CONTENT_TYPE'=>'application/json').status
    assert_equal 403,@client.post('/gollum/projectbook/tasks',input:body,'CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1','HTTP_ORIGIN'=>'https://foreign.test').status
    reply=@client.post('/gollum/projectbook/tasks',input:body,'CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1')
    assert_equal 200,reply.status,reply.body
    assert_equal 1,JSON.parse(@client.get('/gollum/projectbook/tasks').body)['tasks'].size
    Precious::App.set :wiki_options,{ref:'main',allow_editing:false}
    assert_equal 403,@client.post('/gollum/projectbook/tasks',input:body,'CONTENT_TYPE'=>'application/json','HTTP_X_PROJECTWIKI_REQUEST'=>'1').status
    assert_equal false,JSON.parse(@client.get('/gollum/projectbook/tasks').body)['editable']
  end
  def test_source_links_ignore_code_and_external_urls_and_use_current_snapshot
    write([list,task])
    wiki.write_page('Definition',:markdown,"# Definition\n\n[TODO: Oil](Tasks/#{TASK}.md)\n",message:'Source')
    wiki.write_page('Examples',:markdown,"# Examples\n\n`[TODO: Oil](Tasks/#{TASK}.md)`\n\n```markdown\n[TODO: Oil](Tasks/#{TASK}.md)\n```\n\n[TODO: Oil](https://outside.test/Tasks/#{TASK}.md)\n",message:'Examples only')
    catalog=Gollum::ProjectbookTasks.catalog(service,sources:true)
    assert_equal ['Definition.md'],catalog[:tasks][0]['source_references']
    assert_equal 'Definition.md',catalog[:tasks][0]['source_target']
    before=head
    wiki.write_page('Other',:markdown,"# Other\n\n[TODO: Oil](Tasks/#{TASK}.md)\n",message:'Another source')
    item=Gollum::ProjectbookTasks.catalog(service,sources:true)[:tasks][0]
    assert_equal ['Definition.md','Other.md'],item['source_references']
    assert_equal ".projectbook/tasks/#{TASK}.md",item['source_target']
    historic=Gollum::ProjectbookTasks.catalog(Gollum::ProjectbookKnowledge.new(wiki,revision:before),sources:true)
    assert_equal ['Definition.md'],historic[:tasks][0]['source_references']
  end

  def test_editor_records_origin_and_reference_index_follows_moves
    input={'path'=>'Home.md','etag'=>wiki.page('Home.md').sha,'content'=>"# Home\n\n[TODO: Oil](Tasks/#{TASK}.md)\n",'todos'=>[list,task]}
    Gollum::ProjectbookSave.save(wiki,input,[],{message:'Create source'})
    assert_equal 'Home.md',service.read_todo(id:TASK)['source_path']
    input={'source_path'=>'Home.md','path'=>'Moved.md','etag'=>wiki.page('Home.md').sha,'content'=>wiki.page('Home.md').text_data,'move_revision'=>head}
    Gollum::ProjectbookSave.save(wiki,input,[],{message:'Move source'})
    item=Gollum::ProjectbookTasks.catalog(service,sources:true)[:tasks][0]
    assert_equal ['Moved.md'],item['source_references']
    assert_equal 'Moved.md',item['source_target']
    assert_raises(Gollum::ProjectbookCreation::Error){write([current_task.merge('source_path'=>'../escape.md')])}
    assert_raises(Gollum::ProjectbookCreation::Error){write([current_task.merge('source_path'=>3)])}
  end

  def test_hidden_storage_is_not_a_document_but_remains_available_via_todo_api
    write([list,task])
    assert_equal ".projectbook/tasks/#{TASK}.md", service.read_todo(id:TASK)[:path]
    refute Gollum::NavigationIndex.for(wiki).entries.any? { |entry| entry.path.start_with?('.projectbook/') }
    assert_empty service.search_documents(query:'projectbook-todo')[:items]
    assert_empty service.list_tree[:items].select { |item| item[:path].start_with?('.projectbook') }
    assert_raises(Gollum::ProjectbookCreation::Error) { Gollum::ProjectbookSave.path!(".projectbook/tasks/#{TASK}.md") }
    result=@client.get('/gollum/search?q=projectbook-todo')
    assert_equal 200,result.status
    refute_includes result.body,"/.projectbook/tasks/#{TASK}"
    assert_raises(Gollum::ProjectbookCreation::Error) { Gollum::ProjectbookSave.destination!(wiki,'.projectbook/arbitrary.md',system_task:true) }
  end

  def legacy_book
    wiki.write_file("TaskLists/#{LIST}.md",Gollum::ProjectbookTasks.serialize(list),message:'Legacy list',normalize:false)
    wiki.write_file("Tasks/#{TASK}.md",Gollum::ProjectbookTasks.serialize(task),message:'Legacy task',normalize:false)
    wiki.write_page('Notes',:markdown,"# Notes\n\n[TODO: Oil](Tasks/#{TASK}.md)\n\n[TODO list: Spring](TaskLists/#{LIST}.md?status=open)\n",message:'Legacy links')
  end

  def test_storage_migration_is_atomic_idempotent_and_keeps_history_and_ids
    legacy_book
    before=head
    original=service.read_todo(id:TASK)[:version]
    result=Gollum::ProjectbookTaskMigration.run(wiki)
    assert_equal 2,result[:moved]
    assert_equal 1,result[:documents]
    assert_equal before,wiki.commit_for('main').parent.id
    refute File.exist?(File.join(@dir,"Tasks/#{TASK}.md"))
    assert_equal original,service.read_todo(id:TASK)[:version]
    assert_includes wiki.page('Notes.md').text_data,"(.projectbook/tasks/#{TASK}.md)"
    assert_includes wiki.page('Notes.md').text_data,"(.projectbook/task-lists/#{LIST}.md?status=open)"
    assert_equal ['Notes.md'],Gollum::ProjectbookTasks.catalog(service,sources:true)[:tasks][0]['source_references']
    assert_equal original,Gollum::ProjectbookKnowledge.new(wiki,revision:before).read_todo(id:TASK)[:version]
    after=head
    assert_equal 0,Gollum::ProjectbookTaskMigration.run(wiki)[:moved]
    assert_equal after,head
    write([current_task.merge('status'=>'done')])
    assert_equal 'done',service.read_todo(id:TASK)['status']
  end

  def test_migration_refuses_local_work_without_partial_changes
    legacy_book
    before=head
    File.write(File.join(@dir,'Notes.md'),'Unsaved external work')
    assert_raises(Gollum::ProjectbookCreation::Error){Gollum::ProjectbookTaskMigration.run(wiki)}
    assert_equal before,head
    assert File.exist?(File.join(@dir,"Tasks/#{TASK}.md"))
    refute File.exist?(File.join(@dir,".projectbook/tasks/#{TASK}.md"))
  end

  def test_migration_rewrites_relative_and_reference_links_but_preserves_examples
    moves={"Tasks/#{TASK}.md"=>".projectbook/tasks/#{TASK}.md"}
    input="[TODO: Oil](../Tasks/#{TASK}.md)\n[t]: /Tasks/#{TASK}.md\n`[TODO: Code](../Tasks/#{TASK}.md)`\n```md\n[TODO: Code](../Tasks/#{TASK}.md)\n```\n[External](https://other.test/Tasks/#{TASK}.md)\n"
    result=Gollum::ProjectbookTaskMigration.rewrite(input,'boat/notes.md','boat/notes.md',moves)
    assert_includes result,"(../.projectbook/tasks/#{TASK}.md)"
    assert_includes result,"[t]: /.projectbook/tasks/#{TASK}.md"
    assert_includes result,"`[TODO: Code](../Tasks/#{TASK}.md)`"
    assert_includes result,"```md\n[TODO: Code](../Tasks/#{TASK}.md)\n```"
    assert_includes result,"https://other.test/Tasks/#{TASK}.md"
  end

end
