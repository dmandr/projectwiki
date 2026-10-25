import {test} from 'node:test';
import assert from 'node:assert/strict';
import {todoStore} from '../src/todo-store.mjs';
import {todoLink} from '../src/todo-format.mjs';
const list={kind:'list',id:'11111111-1111-4111-8111-111111111111',title:'Spring',notes:'',version:'l1'};
const task={kind:'task',id:'22222222-2222-4222-8222-222222222222',title:'Oil',notes:'',list_id:list.id,status:'open',due:'',version:'v1'};
function create() {
  let posts=0;
  const store=todoStore({staged:true,fetcher:async(_url,options)=>{
    if(options.method==='POST')posts++;
    return {ok:true,json:async()=>({tasks:[task],lists:[list],errors:[],editable:true})};
  }});return {store,posts:()=>posts};
}
test('reverting task metadata clears dirty state without any network write',async()=>{
  const {store,posts}=create();await store.load();
  await store.change([{...task,status:'done'}]);assert.equal(store.pending().length,1);
  await store.change([{...task,status:'open'}]);assert.equal(store.pending().length,0);
  assert.equal(store.snapshot().tasks[0].status,'open');assert.equal(posts(),0);
});
test('undo/redo new task reference hides/restores its staged metadata without an orphan save',async()=>{
  const {store}=create();await store.load();store.setDocument('# Home','Home.md');
  const fresh={...task,id:'33333333-3333-4333-8333-333333333333',version:'',expected_version:''};
  await store.change([fresh]);assert.equal(store.visiblePending().length,0);
  store.setDocument(todoLink(fresh,'Home.md'),'Home.md');assert.equal(store.visiblePending().length,1);
  store.setDocument(todoLink(list,'Home.md'),'Home.md');assert.equal(store.visiblePending().length,0);
  assert.equal(store.snapshot().tasks.length,1);
  store.setDocument(todoLink(fresh,'Home.md'),'Home.md');assert.equal(store.snapshot().tasks.length,2);
});

test('new task reuses Default list and starts open without sending staged writes',async()=>{
  const {store,posts}=create();await store.load();
  const first=await store.newTask();
  store.setDocument(todoLink(first,'Home.md'),'Home.md');
  const second=await store.newTask();
  store.setDocument(todoLink(first,'Home.md')+'\n'+todoLink(second,'Home.md'),'Home.md');
  assert.equal(first.status,'open');assert.equal(second.list_id,first.list_id);
  assert.notEqual(first.id,second.id);
  assert.equal(store.snapshot().lists.filter(item=>item.title==='Default').length,1);
  assert.equal(store.visiblePending().length,3);assert.equal(posts(),0);
});
test('default list lookup ignores casing and editing preserves legacy fields',async()=>{
  const store=todoStore({staged:true,fetcher:async()=>({ok:true,json:async()=>({tasks:[{...task,notes:'Keep',due:'2026-12-01'}],lists:[{...list,title:'default'}],editable:true,errors:[]})})});
  await store.load();const fresh=await store.newTask();assert.equal(fresh.list_id,list.id);
  const current=store.snapshot().tasks.find(item=>item.id===task.id);
  await store.change([{...current,title:'New text'}]);
  const changed=store.pending().find(item=>item.id===task.id);
  assert.equal(changed.notes,'Keep');assert.equal(changed.due,'2026-12-01');
});
