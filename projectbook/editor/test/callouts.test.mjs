import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fromMarkdown} from 'mdast-util-from-markdown';
import {toMarkdown} from 'mdast-util-to-markdown';
import {calloutTypes,readCallout,calloutMdast,calloutMarkdownExtension} from '../src/callout-format.mjs';
test('all five alert types preserve bold, separate list items, and links',()=>{
  for(const kind of Object.keys(calloutTypes)){
    const source=`> [!${kind}]\n> **Before starting:**\n>\n> - Check oil.\n> - Open the seacock.\n>\n> Read [instructions](engine.md).\n`;
    const value=readCallout(fromMarkdown(source).children[0]);
    assert.equal(value.kind,kind);assert.equal(value.children[1].children.length,2);
    const output=toMarkdown(calloutMdast(value.kind,value.children),{extensions:[calloutMarkdownExtension]});
    assert.match(output,new RegExp('^> \\[!'+kind+'\\]'));
    const restored=readCallout(fromMarkdown(output).children[0]);
    assert.equal(restored.children[1].children.length,2);
    assert.equal(restored.children[0].children[0].type,'strong');
    assert.equal(restored.children[2].children[1].url,'engine.md');
  }
});
test('ordinary quotes and unknown types remain ordinary quotes',()=>{
  for(const source of ['> Just a quote','> [!CUSTOM]\n> text','> ` [!NOTE] `'])assert.equal(readCallout(fromMarkdown(source).children[0]),null);
});
test('callout with a marker-only paragraph and several paragraphs',()=>{
  const value=readCallout(fromMarkdown('> [!NOTE]\n>\n> One\n>\n> Two').children[0]);
  assert.equal(value.children.length,2);
});
