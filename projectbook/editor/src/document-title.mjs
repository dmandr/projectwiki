import { fromMarkdown } from 'mdast-util-from-markdown';
import { toMarkdown } from 'mdast-util-to-markdown';
import { frontmatter } from 'micromark-extension-frontmatter';
import { frontmatterFromMarkdown } from 'mdast-util-frontmatter';

function nodes(source) {
  return fromMarkdown(source, {extensions: [frontmatter(['yaml', 'toml'])], mdastExtensions: [frontmatterFromMarkdown(['yaml', 'toml'])]}).children;
}
const isMetadata = node => ['yaml', 'toml'].includes(node.type);
const plain = node => node.type === 'image' ? node.alt || '' : node.children ? node.children.map(plain).join('') : node.type === 'html' ? '' : node.value || '';

export function documentTitle(source, fallback) {
  const first = nodes(source).find(node => !isMetadata(node));
  return first?.type === 'heading' && first.depth === 1 ? plain(first).trim() || fallback : fallback;
}

export function withDocumentTitle(source, title, fallback = '') {
  title = title.trim();
  if (!title || /[\r\n]/.test(title)) throw new Error('Enter a title on one line.');
  // Keep the original Markdown bytes (including formatting and setext headings)
  // when the user confirms the already displayed title.
  if (title === documentTitle(source, fallback)) return source;
  const children = nodes(source);
  const first = children.find(node => !isMetadata(node));
  const heading = toMarkdown({type: 'heading', depth: 1, children: [{type: 'text', value: title}]}).trimEnd();
  if (first?.type === 'heading' && first.depth === 1) {
    return source.slice(0, first.position.start.offset) + heading + source.slice(first.position.end.offset);
  }
  const metadata = children[0] && isMetadata(children[0]) ? children[0] : null;
  const offset = metadata?.position.end.offset || 0;
  return source.slice(0, offset) + (offset ? '\n\n' : '') + heading + '\n\n' + source.slice(offset).replace(/^\r?\n(?:\r?\n)?/, '');
}
