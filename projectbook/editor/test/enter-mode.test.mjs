import {test} from 'node:test';
import assert from 'node:assert/strict';
import {enterAction} from '../src/enter-mode.mjs';
test('Enter modes and Mac/Windows paragraph modifier',()=>{
 for(const mode of ['paragraph','line-break']) {
  assert.equal(enterAction(mode),mode==='paragraph'?'paragraph':'break');
  for(const modifier of ['metaKey','ctrlKey'])assert.equal(enterAction(mode,{[modifier]:true}),mode==='paragraph'?'break':'paragraph');
  assert.equal(enterAction(mode,{shiftKey:true}),'break');
  assert.equal(enterAction(mode,{isComposing:true}),null);
  assert.equal(enterAction(mode,{altKey:true}),null);
 }
});
