import React from 'react';
import { realmPlugin, addImportVisitor$, addExportVisitor$, $createImageNode, $isImageNode,
  usePublisher, openEditImageDialog$, createActiveEditorSubscription$, ImageNode } from '@mdxeditor/editor';
import { $createParagraphNode, $getNodeByKey, $getSelection, $isNodeSelection, $isParagraphNode,
  KEY_ARROW_UP_COMMAND, KEY_ARROW_DOWN_COMMAND, KEY_ARROW_LEFT_COMMAND, KEY_ARROW_RIGHT_COMMAND,
  KEY_ENTER_COMMAND, KEY_ESCAPE_COMMAND, COMMAND_PRIORITY_HIGH } from 'lexical';
import { useLexicalNodeSelection } from '@lexical/react/useLexicalNodeSelection';
import { useLexicalComposerContext } from '@lexical/react/LexicalComposerContext';

// Keep dimensions in portable HTML inside Markdown. The stock image importer
// parses "23%" as 23 pixels, so override its import/export visitors explicitly.
export function dimension(value) {
  const text = String(value ?? '').trim();
  if (/^\d+(\.\d+)?%$/.test(text) && parseFloat(text) > 0 && parseFloat(text) <= 100) return text;
  if (/^\d+$/.test(text) && Number(text) > 0 && Number(text) <= 10000) return Number(text);
  return 'inherit';
}
export const imageDimensionsPlugin = realmPlugin({init(realm) {
  // Images are blocks in this editor. Keep adjacent text in real paragraphs,
  // including insertions made through the stock image dialog.
  realm.pub(createActiveEditorSubscription$, editor => editor.registerNodeTransform(ImageNode, node => {
    const parent = node.getParent();
    if (!$isParagraphNode(parent) || parent.getChildrenSize() <= 1) return;
    const following = node.getNextSiblings();
    if (following.length) parent.insertAfter($createParagraphNode().append(...following));
    if (node.getPreviousSibling()) parent.insertAfter($createParagraphNode().append(node));
  }));
  realm.pub(addImportVisitor$, {
    priority: 20,
    testNode: node => (node.type === 'html' && /^\s*<img\b/i.test(node.value)) ||
      (['mdxJsxTextElement','mdxJsxFlowElement'].includes(node.type) && node.name === 'img'),
    visitNode({mdastNode, lexicalParent}) {
      let attrs;
      if (mdastNode.type === 'html') {
        const wrapper = document.createElement('template'); wrapper.innerHTML = mdastNode.value;
        const img = wrapper.content.querySelector('img');
        attrs = Object.fromEntries(Array.from(img.attributes).map(attr => [attr.name, attr.value]));
      } else attrs = Object.fromEntries(mdastNode.attributes.filter(attr => attr.type === 'mdxJsxAttribute' && typeof attr.value === 'string').map(attr => [attr.name, attr.value]));
      const width = dimension(attrs.width);
      const node = $createImageNode({src: attrs.src || '', altText: attrs.alt || '', title: attrs.title || '',
        width, height: typeof width === 'string' && width.endsWith('%') ? 'inherit' : dimension(attrs.height),
        rest: Object.entries(attrs).filter(([key]) => !['src','alt','title','width','height'].includes(key)).map(([name,value]) => ({type: 'mdxJsxAttribute',name,value}))});
      if (lexicalParent.getType() === 'root') lexicalParent.append($createParagraphNode().append(node));
      else lexicalParent.append(node);
    }
  });
  realm.pub(addExportVisitor$, {
    priority: 20, testLexicalNode: $isImageNode,
    visitLexicalNode({mdastParent, lexicalNode: node, actions}) {
      if (node.getWidth() === 'inherit' && node.getHeight() === 'inherit' && !node.getRest().length) {
        actions.appendToParent(mdastParent, {type: 'image', url: node.getSrc(), alt: node.getAltText(), title: node.getTitle()}); return;
      }
      const image = document.createElement('img');
      image.setAttribute('src', node.getSrc()); image.setAttribute('alt', node.getAltText());
      if (node.getTitle()) image.setAttribute('title', node.getTitle());
      for (const attr of node.getRest()) if (attr.type === 'mdxJsxAttribute' && typeof attr.value === 'string') image.setAttribute(attr.name, attr.value);
      if (node.getWidth() !== 'inherit') image.setAttribute('width', String(node.getWidth()));
      if (node.getHeight() !== 'inherit') image.setAttribute('height', String(node.getHeight()));
      actions.appendToParent(mdastParent, {type: 'html', value: image.outerHTML.replace(/>$/, ' />')});
    }
  });
} });

export function ImageToolbar({nodeKey, width, imageSource, initialImagePath, alt, title}) {
  const [editor] = useLexicalComposerContext();
  const [selected, setSelected] = useLexicalNodeSelection(nodeKey);
  React.useEffect(() => {
    const outside = event => {
      if (!editor.getElementByKey(nodeKey)?.contains(event.target)) setSelected(false);
    };
    document.addEventListener('pointerdown', outside, true);
    return () => document.removeEventListener('pointerdown', outside, true);
  }, [editor, nodeKey, setSelected]);
  React.useEffect(() => {
    const move = (event, before) => {
      const selection = $getSelection();
      if (!$isNodeSelection(selection) || !selection.has(nodeKey) || event?.target?.closest('.pb-image-tools')) return false;
      const node = $getNodeByKey(nodeKey), block = node?.getParent();
      if (!$isParagraphNode(block)) return false;
      let neighbor = before ? block.getPreviousSibling() : block.getNextSibling();
      if (!$isParagraphNode(neighbor) || neighbor.getChildren().some($isImageNode)) {
        neighbor = $createParagraphNode();
        if (before) block.insertBefore(neighbor); else block.insertAfter(neighbor);
      }
      if (before) neighbor.selectEnd(); else neighbor.selectStart();
      event?.preventDefault(); return true;
    };
    const unregister = [
      [KEY_ARROW_UP_COMMAND, true], [KEY_ARROW_LEFT_COMMAND, true],
      [KEY_ARROW_DOWN_COMMAND, false], [KEY_ARROW_RIGHT_COMMAND, false], [KEY_ENTER_COMMAND, false]
    ].map(([command, before]) => editor.registerCommand(command, event => move(event, before), COMMAND_PRIORITY_HIGH));
    unregister.push(editor.registerCommand(KEY_ESCAPE_COMMAND, event => {
      const selection = $getSelection();
      if (!$isNodeSelection(selection) || !selection.has(nodeKey)) return false;
      selection.delete(nodeKey); event?.preventDefault(); return true;
    }, COMMAND_PRIORITY_HIGH));
    return () => unregister.forEach(remove => remove());
  }, [editor, nodeKey]);
  const openDialog = usePublisher(openEditImageDialog$);
  const [value, setValue] = React.useState(width === 'inherit' ? '' : String(width));
  React.useEffect(() => setValue(width === 'inherit' ? '' : String(width)), [width]);
  const resize = next => editor.update(() => {
    const node = $getNodeByKey(nodeKey);
    if ($isImageNode(node)) node.setWidthAndHeight(dimension(next), 'inherit');
  });
  if (!selected) return null;
  return <div className="pb-image-tools" contentEditable={false} onMouseDown={event => event.stopPropagation()}>
    <span>Width</span>
    {['Original','25%','50%','75%','100%'].map(size => <button type="button" key={size}
      title={size === 'Original' ? 'Original image size' : size + ' of text width'}
      aria-pressed={(size === 'Original' && width === 'inherit') || width === size}
      onClick={() => resize(size === 'Original' ? '' : size)}>{size}</button>)}
    <input aria-label="Image width" placeholder="23% or 640" value={value} onChange={event => setValue(event.target.value)}
      onKeyDown={event => {if (event.key === 'Enter') {event.preventDefault(); event.stopPropagation(); if (!value || dimension(value) !== 'inherit') resize(value);}}}/>
    <button type="button" disabled={!!value && dimension(value) === 'inherit'} onClick={() => { resize(value); setSelected(false); }}>Apply</button>
    <button type="button" title="Edit image" onClick={() => openDialog({nodeKey, initialValues: {src: initialImagePath || imageSource, altText: alt, title}})}>Edit</button>
    <button type="button" title="Delete image" onClick={() => editor.update(() => $getNodeByKey(nodeKey)?.remove())}>Remove</button>
  </div>;
}
