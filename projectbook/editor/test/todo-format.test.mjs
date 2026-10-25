import {test} from 'node:test';
import assert from 'node:assert/strict';
import {todoLink,todoReference,todoReferences,pendingTodos,renderedTodoReference} from '../src/todo-format.mjs';
import {rebaseMarkdown} from '../src/move-links.mjs';
const id='11111111-1111-4111-8111-111111111111';
const list={kind:'list',id,title:'Весна [2027]',expected_version:''};
const task={kind:'task',id:'22222222-2222-4222-8222-222222222222',title:'Oil',list_id:id,expected_version:''};
test('nested list links survive document moves, labels and status filters',()=>{
  const source=todoLink(list,'boat/notes.md','open');
  const ref=todoReferences(source,'boat/notes.md')[0];
  assert.equal(ref.id,id);assert.equal(ref.status,'open');assert.equal(ref.label,'TODO list: Весна [2027]');
  const moved=rebaseMarkdown(source,'boat/notes.md','archive/boat/notes.md');
  assert.equal(todoReferences(moved,'archive/boat/notes.md')[0].id,id);
});
test('ordinary/external links and code examples are not task references',()=>{
  assert.equal(todoReference('https://other.test/TaskLists/'+id+'.md','TODO list: Test'),null);
  assert.equal(todoReference('TaskLists/'+id+'.md','Ordinary link'),null);
  assert.equal(todoReferences('```md\n'+todoLink(list,'Home.md')+'\n```','Home.md').length,0);
});
test('undoing a new task insertion drops its unreferenced task and list files',()=>{
  assert.equal(pendingTodos([list,task],'# Home','Home.md').length,0);
  assert.equal(pendingTodos([list,task],todoLink(task,'Home.md'),'Home.md').length,2);
  assert.equal(pendingTodos([list,task],todoLink(list,'Home.md'),'Home.md').length,1);
});

test('rendered links resolve from the original page path even on historical URLs',()=>{
  const ref=renderedTodoReference('../TaskLists/'+id+'.md?status=open','TODO list: Spring','boat/notes.md','/book','https://wiki.test');
  assert.equal(ref.id,id);assert.equal(ref.status,'open');
  assert.equal(renderedTodoReference('https://foreign.test/Tasks/'+id+'.md','TODO: Other','Home.md','','https://wiki.test'),null);
});


test('source links encode file paths and keep history pinned',async()=>{
  const {todoSourceUrl}=await import('../src/todo-format.mjs');
  const item={id:'22222222-2222-4222-8222-222222222222',source_target:'Boat notes/Покупки.md'};
  assert.equal(todoSourceUrl(item,'/book'),'/book/Boat%20notes/'+encodeURIComponent('Покупки.md')+'#todo-'+item.id);
  assert.equal(todoSourceUrl({...item,source_target:'Moved.md',source_path:'Old.md'},'', 'abc'),'/Moved.md/abc#todo-'+item.id);
  assert.equal(todoSourceUrl({id:item.id}),'/' + '.projectbook/tasks/'+item.id+'.md#todo-'+item.id);
});


test('new references use system paths while old document revisions still resolve',()=>{
  assert.match(todoLink(task,'boat/notes.md'), /\(\.\.\/\.projectbook\/tasks\//);
  for(const prefix of ['Tasks','.projectbook/tasks'])assert.equal(todoReference('../'+prefix+'/'+task.id+'.md','TODO: Oil','boat/notes.md').id,task.id);
  for(const prefix of ['TaskLists','.projectbook/task-lists'])assert.equal(todoReference('../'+prefix+'/'+list.id+'.md?status=done','TODO list: Spring','boat/notes.md').status,'done');
});
