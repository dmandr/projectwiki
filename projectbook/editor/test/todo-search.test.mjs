import {test} from 'node:test';
import assert from 'node:assert/strict';
import {filterTodoTasks,matchesTodoQuery} from '../src/todo-search.mjs';

test('task search intersects selected lists and matches all words without case sensitivity',()=>{
  const tasks=[{id:'a',list_id:'spring',title:'Купить масло для двигателя'},{id:'b',list_id:'autumn',title:'Масло для двигателя купить'},{id:'c',list_id:'spring',title:'Купить фильтр'}];
  assert.deepEqual(filterTodoTasks(tasks,'МАСЛО купить',['spring']).map(t=>t.id),['a']);
  assert.deepEqual(filterTodoTasks(tasks,'  купить  масло ',['spring','autumn']).map(t=>t.id),['a','b']);
  assert.deepEqual(filterTodoTasks(tasks,'',[]),[]);
  assert.equal(matchesTodoQuery('Ｆｉｌｔｅｒ','filter'),true);
});
test('filtering hundreds of tasks does not truncate results or mutate catalog',()=>{
  const tasks=Array.from({length:600},(_,i)=>({id:String(i),list_id:i%2?'autumn':'spring',title:'Check engine '+i}));
  assert.equal(filterTodoTasks(tasks,'engine',['spring','autumn']).length,600);
  assert.equal(filterTodoTasks(tasks,'engine',['spring']).length,300);
  assert.equal(filterTodoTasks(tasks,'engine 599',['autumn'])[0].id,'599');
  assert.equal(tasks.length,600);
});
