import test from 'node:test';
import assert from 'node:assert/strict';
import { documentTitle, withDocumentTitle } from '../src/document-title.mjs';

test('display title uses the leading H1, including setext and inline formatting', () => {
  assert.equal(documentTitle('# Boat **notes**\n\nText', 'file'), 'Boat notes');
  assert.equal(documentTitle('Boat notes\n==========\n\nText', 'file'), 'Boat notes');
  assert.equal(documentTitle('Intro\n\n# Later section', 'file'), 'file');
});
test('renaming replaces only the title, preserving body bytes and links', () => {
  const source = '# Old\n\n![Photo](assets/a.png)\n\n# Later\n\n  - spacing\n';
  assert.equal(withDocumentTitle(source, 'Русское название'), '# Русское название\n\n![Photo](assets/a.png)\n\n# Later\n\n  - spacing\n');
});
test('new title preserves frontmatter and existing content', () => {
  const source = '---\ntags: [boat]\n---\n\nIntro\n\n# Section\n';
  const result = withDocumentTitle(source, 'New title');
  assert.equal(result, '---\ntags: [boat]\n---\n\n# New title\n\nIntro\n\n# Section\n');
  assert.equal(documentTitle(result, 'file'), 'New title');
});
test('plain-text title cannot inject links or HTML', () => {
  const title = 'A *literal* [title](url) <img src=x> & more';
  assert.equal(documentTitle(withDocumentTitle('Body', title), ''), title);
});
test('empty/multiline titles are rejected; new document gets a real paragraph boundary', () => {
  assert.throws(() => withDocumentTitle('Body', '   '));
  assert.throws(() => withDocumentTitle('Body', 'First\nSecond'));
  assert.equal(withDocumentTitle('![x](image.png)', 'Title'), '# Title\n\n![x](image.png)');
});

import { titleFromPath, titleFromInput, slugFromTitle } from '../src/names.mjs';
test('path and title conversion is predictable and preserves human titles', () => {
  assert.equal(titleFromPath('boat/log/engine_check.md'), 'Engine Check');
  assert.equal(titleFromInput('engine-check'), 'Engine Check');
  assert.equal(titleFromInput('Engine check: API'), 'Engine check: API');
  assert.equal(slugFromTitle('Engine check: API'), 'engine-check-api');
  assert.equal(slugFromTitle('Проверка двигателя'), 'proverka-dvigatelya');
  assert.equal(slugFromTitle('Café déjà vu'), 'cafe-deja-vu');
});

test('confirming the displayed title preserves Markdown exactly', () => {
  for (const source of ['# Same **title**\r\n\r\nBody\r\n', 'Same title\n==========\n\nBody', '# Same title\n\nBody']) {
    assert.equal(withDocumentTitle(source, '  Same title  '), source);
  }
  assert.equal(withDocumentTitle('Body without heading', 'Fallback Title', 'Fallback Title'), 'Body without heading');
  assert.equal(withDocumentTitle('Body without heading', 'Changed', 'Fallback Title'), '# Changed\n\nBody without heading');
});
