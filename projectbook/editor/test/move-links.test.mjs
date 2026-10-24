import test from 'node:test';
import assert from 'node:assert/strict';
import { rebaseMarkdown, rebaseUrl } from '../src/move-links.mjs';

test('move preserves targets, fragments, spaces and external links', () => {
  assert.equal(rebaseUrl('../assets/photo.png?raw=1#preview', 'notes/Page.md', 'archive/2026/Renamed.md'), '../../assets/photo.png?raw=1#preview');
  assert.equal(rebaseUrl('Page.md#title', 'notes/Page.md', 'archive/New.md'), 'New.md#title');
  assert.equal(rebaseUrl('../space%20folder/a.pdf', 'notes/Page.md', 'New.md'), 'space%20folder/a.pdf');
  for (const url of ['https://example.com/a', 'mailto:a@example.com', '/assets/a.png', '#section', '?raw', '//example.com/a']) {
    assert.equal(rebaseUrl(url, 'notes/Page.md', 'archive/New.md'), url);
  }
});

test('rewrite Markdown links, images and definitions without touching code or frontmatter', () => {
  const source = '---\nnote: "[not a link](pic.png)"\n---\n\n# Keep heading\n\n[Manual](files/a.pdf "Title") and ![Photo](pic.png)\n\n[ref]: files/b.pdf "Reference"\n\n[Read][ref]\n\n`[example](pic.png)`\n\n```md\n![example](pic.png)\n```\n';
  const result = rebaseMarkdown(source, 'notes/Page.md', 'archive/deep/New.md');
  assert.ok(result.includes('[Manual](../../notes/files/a.pdf "Title")'));
  assert.ok(result.includes('![Photo](../../notes/pic.png)'));
  assert.ok(result.includes('[ref]: ../../notes/files/b.pdf "Reference"'));
  assert.ok(result.includes('note: "[not a link](pic.png)"'));
  assert.ok(result.includes('`[example](pic.png)`'));
  assert.ok(result.endsWith('```md\n![example](pic.png)\n```\n'));
});

test('nested linked images are edited once and unchanged source is byte-exact', () => {
  assert.equal(rebaseMarkdown('[![x](pic.png)](doc.md)', 'old/Page.md', 'new/Page.md'), '[![x](../old/pic.png)](../old/doc.md)');
  const source = '# H\n\n  - spaced\n\n[Link](https://example.com)\n';
  assert.equal(rebaseMarkdown(source, 'old.md', 'new.md'), source);
  assert.equal(rebaseMarkdown(source, 'old.md', 'old.md'), source);
});
