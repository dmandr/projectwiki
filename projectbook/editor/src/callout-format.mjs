import {defaultHandlers} from 'mdast-util-to-markdown';
export const calloutTypes = {NOTE:'Note',TIP:'Tip',IMPORTANT:'Important',WARNING:'Warning',CAUTION:'Caution'};
export function readCallout(node) {
  if (node.type !== 'blockquote') return null;
  const first = node.children?.[0];
  const text = first?.type === 'paragraph' && first.children?.[0];
  if (!text || text.type !== 'text') return null;
  const match = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\n|$)/.exec(text.value);
  if (!match) return null;
  const rest = text.value.slice(match[0].length);
  const inline = [...(rest ? [{...text,value:rest}] : []), ...first.children.slice(1)];
  if (inline[0]?.type === 'break') inline.shift();
  return {kind:match[1], children:[...(inline.length ? [{...first,children:inline}] : []), ...node.children.slice(1)]};
}
export function calloutMdast(kind,children=[]) {
  return {type:'blockquote',children:[{type:'paragraph',children:[{type:'text',value:`[!${kind}]`}]},...children]};
}

export const calloutMarkdownExtension = {handlers:{blockquote(node,parent,state,info) {
  const output=defaultHandlers.blockquote(node,parent,state,info);
  // Only our recognized leading marker is literal; preserve escaping in the body.
  return readCallout(node) ? output.replace('> \\[!', '> [!') : output;
}}};
