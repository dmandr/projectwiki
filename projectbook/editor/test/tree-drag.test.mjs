import {test} from 'node:test';
import assert from 'node:assert/strict';
import {dropIntent} from '../src/tree-drag.mjs';
test('folder middle moves; edges reorder siblings', () => {
  assert.deepEqual(dropIntent('a/doc.md','b',true,.5),{action:'move',folder:'b'});
  assert.deepEqual(dropIntent('a','b',true,.1),{action:'reorder',folder:'',position:'before'});
  assert.equal(dropIntent('a/doc.md','a',true,.5),null);
  assert.equal(dropIntent('a/doc.md','b/other.md',false,.2),null);
  assert.deepEqual(dropIntent('a/doc.md','a/other.md',false,.8),{action:'reorder',folder:'a',position:'after'});
  assert.equal(dropIntent('a/doc.md','a/doc.md',false,.5),null);
  assert.deepEqual(dropIntent('plan.md','first-folder',true,.30),{action:'reorder',folder:'',position:'before'});
  assert.deepEqual(dropIntent('plan.md','first-folder',true,.70),{action:'reorder',folder:'',position:'after'});
});
