import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readTodo,todoMarkdown,scanInlineTodos,editTodoTags,todoListMarkdown,readTodoList,matchesTodo} from '../src/inline-todo-format.mjs';
test('inline definitions, case insensitive, punctuation and escaped titles',()=>{
 const task={title:'Масло [5л] & фильтр',done:'',tags:['весна','engine']};
 assert.deepEqual(scanInlineTodos('До '+todoMarkdown(task)+' после').tasks.map(t=>({title:t.title,tags:t.tags,done:t.done})),[{...task,tags:['engine','весна']}]);
 assert.deepEqual(readTodo('todo: масло',''),{title:'масло',done:'',tags:[]});
 assert.equal(readTodo('TODO: old','.projectbook/tasks/id.md'),null);
});
test('completed metadata and no tasks inside code or escaped brackets',()=>{
 const text='[todo: Oil](done=2026-11-03T11:22,tags=aaa,bbb)';
 assert.equal(scanInlineTodos(text).tasks[0].done,'2026-11-03T11:22');
 assert.equal(scanInlineTodos('`'+text+'`\n\n```md\n'+text+'\n```\n\n\\[TODO: literal]()').tasks.length,0);
});
test('identical occurrences stay independent and edits retain surrounding text',()=>{
 const text='[TODO: Oil]()\\\n[TODO: Oil](tags=engine)';
 const tasks=scanInlineTodos(text).tasks;
 assert.equal(tasks.length,2);assert.notEqual(tasks[0].start,tasks[1].start);
 const result=editTodoTags(text,tasks,{add:['spring'],remove:[]});
 assert.equal(result,'[TODO: Oil](tags=spring)\\\n[TODO: Oil](tags=engine,spring)');
 assert.equal(editTodoTags(text,[tasks[1]],{add:[],remove:['engine']}),'[TODO: Oil]()\\\n[TODO: Oil]()');
});
test('query blocks and all/any matching',()=>{
 const query={tags:['engine','spring'],match:'all',status:'open'};
 assert.deepEqual(readTodoList(todoListMarkdown(query)),query);
 assert.equal(scanInlineTodos(todoListMarkdown(query)).lists.length,1);
 assert.equal(matchesTodo({tags:['spring'],done:''},query),false);
 assert.equal(matchesTodo({tags:['spring'],done:''},{...query,match:'any'}),true);
});
test('moving a document preserves inline metadata and query blocks',async()=>{
 const {rebaseMarkdown}=await import('../src/move-links.mjs');
 const {rewriteBookLinks}=await import('../src/book-links.mjs');
 const source='[TODO: Oil](done=2026-11-03T11:22,tags=spring)\n\n'+todoListMarkdown({tags:['spring']});
 assert.equal(rebaseMarkdown(source,'a.md','folder/a.md'),source);
 assert.equal(rewriteBookLinks(source,'a.md','folder/a.md','a.md','folder/a.md',['a.md']),source);
});
