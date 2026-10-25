import { fromMarkdown } from 'mdast-util-from-markdown';
import { toMarkdown } from 'mdast-util-to-markdown';
import {gfmFootnote} from 'micromark-extension-gfm-footnote';
import {gfmFootnoteFromMarkdown,gfmFootnoteToMarkdown} from 'mdast-util-gfm-footnote';
import { frontmatter } from 'micromark-extension-frontmatter';
import { frontmatterFromMarkdown } from 'mdast-util-frontmatter';

const encoded = path => path.split('/').map(encodeURIComponent).join('/');

// Resolve against the old document, then express the same destination relative
// to its new directory. Absolute URLs, book-root URLs and local anchors stay put.
export function rebaseUrl(value, from, to) {
  if (!value || /^(?:[a-z][a-z\d+.-]*:|\/|#|\?)/i.test(value)) return value;
  const old = new URL(encoded(from), 'https://book.invalid/');
  const url = new URL(value, old);
  if (url.origin !== old.origin) return value;
  if (url.pathname === old.pathname) url.pathname = '/' + encoded(to);
  const destination = url.pathname.slice(1).split('/');
  const parent = encoded(to).split('/').slice(0, -1);
  while (parent.length && destination.length && parent[0] === destination[0]) { parent.shift(); destination.shift(); }
  return ('../'.repeat(parent.length) + destination.join('/') || './') + url.search + url.hash;
}

function rebaseHtml(html, from, to) {
  // Rewrite individual opening tags, not a serialized HTML fragment: serializing
  // an inline <a> node would add </a> before its Markdown text. Leave comments
  // and raw/code blocks untouched, and decode attributes in an inert template.
  return html.replace(/<!--[\s\S]*?-->|<(script|style|pre|code)\b[^>]*>[\s\S]*?<\/\1\s*>|<[a-z][\w:-]*\b(?:[^"'<>]|"[^"]*"|'[^']*')*>/gi, (tag, raw) => {
    if (raw || tag.startsWith('<!--')) return tag;
    const template = document.createElement('template');
    template.innerHTML = tag;
    const element = template.content.firstElementChild;
    if (!element) return tag;
    let changed = false;
    for (const attr of ['src', 'href']) {
      const original = element.getAttribute(attr);
      if (original == null) continue;
      const next = rebaseUrl(original, from, to);
      if (next !== original) { element.setAttribute(attr, next); changed = true; }
    }
    if (!changed) return tag;
    const opening = element.outerHTML.match(/^<(?:[^"'<>]|"[^"]*"|'[^']*')*>/)[0];
    // DOM drops the slash on void elements; MDX requires it on re-import.
    return /\/\s*>$/.test(tag) || /^(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)$/i.test(element.tagName)
      ? opening.replace(/>$/, ' />') : opening;
  });
}

export function rebaseMarkdown(source, from, to) {
  if (from === to) return source;
  const tree = fromMarkdown(source, {extensions: [frontmatter(['yaml', 'toml']),gfmFootnote()], mdastExtensions: [frontmatterFromMarkdown(['yaml', 'toml']),gfmFootnoteFromMarkdown()]});
  const edits = [];
  function rewrite(node) {
    let changed = false;
    if (['link', 'image', 'definition'].includes(node.type)) {
      const next = rebaseUrl(node.url, from, to);
      changed = next !== node.url; node.url = next;
    }
    if (node.type === 'html') {
      const next = rebaseHtml(node.value, from, to);
      changed = next !== node.value; node.value = next;
    }
    for (const child of node.children || []) changed = rewrite(child) || changed;
    return changed;
  }
  function visit(node) {
    if (['link', 'image', 'definition', 'html'].includes(node.type)) {
      if (rewrite(node)) edits.push({start: node.position.start.offset, end: node.position.end.offset,
        text: node.type === 'html' ? node.value : toMarkdown(node,{extensions:[gfmFootnoteToMarkdown()]}).trimEnd()});
    } else for (const child of node.children || []) visit(child);
  }
  visit(tree);
  // Preserve all source bytes outside changed link/image nodes (including code).
  for (const edit of edits.sort((a, b) => b.start - a.start)) source = source.slice(0, edit.start) + edit.text + source.slice(edit.end);
  return source;
}
