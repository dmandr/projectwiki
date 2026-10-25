import test from 'node:test';
import assert from 'node:assert/strict';
import {rewriteBookLinks} from '../src/book-links.mjs';
const paths=['boat/manual.md','boat/photo.png','boat/sub/part.md','outside.md'];
const rewrite=(text,from='outside.md',to=from)=>rewriteBookLinks(text,from,to,'boat','archive/boat',paths);
test('incoming Markdown, reference, wiki and HTML links preserve anchors/query',()=>{
 const text='[Read](boat/manual.md#oil) ![Photo](/boat/photo.png)\n\n[ref]: boat/manual?x=1#oil\n\n[[Manual|boat/manual#oil]]\n\n<a href="boat/manual.md?x=1&amp;y=2#oil">Read</a> <img src="boat/photo.png" width="23%" />\n';
 const result=rewrite(text);
 assert.match(result,/archive\/boat\/manual.md#oil/);
 assert.match(result,/\/archive\/boat\/photo.png/);
 assert.match(result,/\[ref\]: archive\/boat\/manual.md\?x=1#oil/);
 assert.match(result,/\[\[Manual\|archive\/boat\/manual.md#oil\]\]/);
 assert.match(result,/href="archive\/boat\/manual.md\?x=1&amp;y=2#oil"/);
 assert.match(result,/width="23%"/);
});
test('whole-folder move keeps internal links and rebases outgoing links',()=>{
 const moved=rewrite('[Part](sub/part.md) [Other](../outside.md) ![](photo.png)','boat/manual.md','archive/boat/manual.md');
 assert.equal(moved,'[Part](sub/part.md) [Other](../../outside.md) ![](photo.png)');
});
test('HTML containers rewrite real links but leave nested code examples alone',()=>{
 const text='<div>\n<a href="boat/manual.md">Read</a>\n<pre><a href="boat/manual.md">Code</a></pre>\n<!-- <img src="boat/photo.png"> -->\n</div>\n';
 const result=rewrite(text);
 assert.match(result,/<a href="archive\/boat\/manual.md">Read/);
 assert.match(result,/<pre><a href="boat\/manual.md">Code/);
 assert.match(result,/<!-- <img src="boat\/photo.png"> -->/);
});
test('code, comments, frontmatter and external URLs stay byte exact',()=>{
 const text='---\nx: "[[boat/manual]]"\n---\n\n`[[boat/manual]] [x](boat/manual.md)`\n\n```md\n[x](boat/manual.md)\n```\n\n<!-- [[boat/manual]] -->\n\n<pre><a href="boat/manual.md">Example</a></pre>\n\n[external](https://example.com/boat/manual.md) <code>[[boat/manual]]</code>\n';
 assert.equal(rewrite(text),text);
});
test('root application routes, encoded spaces, self links and footnotes',()=>{
 const result=rewriteBookLinks('[File](/gollum/file/old/a%20b.pdf#p) [Me](page.md#h)\n\n[^x]: [Read](page.md)\n','old/page.md','new/page.md','old','new',['old/page.md','old/a b.pdf']);
 assert.match(result,/\/gollum\/file\/new\/a%20b.pdf#p/);
 assert.match(result,/\[Me\]\(page.md#h\)/);
 assert.match(result,/\[\^x\]: \[Read\]\(page.md\)/);
});
