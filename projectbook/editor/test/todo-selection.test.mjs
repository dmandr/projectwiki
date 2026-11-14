import {test} from 'node:test';
import assert from 'node:assert/strict';
import {todoTitles} from '../src/todo-selection.mjs';
test('selected text, CRLF and blank lines',()=>{
  assert.deepEqual(todoTitles('Купить масло'),['Купить масло']);
  assert.deepEqual(todoTitles('Oil\r\n\r\n Filter\nWater'),['Oil','Filter','Water']);
  assert.deepEqual(todoTitles(' \n '),[]);
});
test('source list markers are excluded',()=>{
  assert.deepEqual(todoTitles('- Oil\n* [ ] Filter\n2. Water\n3) Fuel',true),['Oil','Filter','Water','Fuel']);
  assert.deepEqual(todoTitles('-5 degrees\nC++'),['-5 degrees','C++']);
});

test('Markdown hard breaks remain outside TODO links',async()=>{
  const {sourceTodoSelection}=await import('../src/todo-selection.mjs');
  const selected=sourceTodoSelection('Oil\\\nFilter\\\nWater', '\n');
  assert.deepEqual(selected.titles,['Oil','Filter','Water']);
  assert.equal(selected.render(['[Oil](todo:1)','[Filter](todo:2)','[Water](todo:3)']),
    '[Oil](todo:1)\\\n[Filter](todo:2)\\\n[Water](todo:3)');
});
test('preserves blank lines, space breaks, CRLF and selection-end breaks',async()=>{
  const {sourceTodoSelection}=await import('../src/todo-selection.mjs');
  const selected=sourceTodoSelection('- Oil  \r\n\r\n* [ ] Filter\\', '\r\nTail');
  assert.deepEqual(selected.titles,['Oil','Filter']);
  assert.equal(selected.render(['A','B']),'A  \r\n\r\nB\\');
});
test('literal backslashes are not mistaken for hard breaks',async()=>{
  const {sourceTodoSelection}=await import('../src/todo-selection.mjs');
  assert.deepEqual(sourceTodoSelection('Path\\\\\nNext').titles,['Path\\\\','Next']);
  assert.deepEqual(sourceTodoSelection('Path\\').titles,['Path\\']);
  assert.deepEqual(todoTitles('Path\\\nNext'),['Path\\','Next']);
});
