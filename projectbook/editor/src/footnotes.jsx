import React from 'react';
import {createPortal} from 'react-dom';
import {ElementNode,DecoratorNode,$applyNodeReplacement,$createParagraphNode,$createTextNode,$getRoot,$getSelection,$isRangeSelection,$setSelection} from 'lexical';
import {useLexicalComposerContext} from '@lexical/react/LexicalComposerContext';
import {realmPlugin,addLexicalNode$,addImportVisitor$,addExportVisitor$,addSyntaxExtension$,addMdastExtension$,addToMarkdownExtension$,activeEditor$,readOnly$} from '@mdxeditor/editor';
import {useCellValue} from '@mdxeditor/gurx';
import {gfmFootnote} from 'micromark-extension-gfm-footnote';
import {gfmFootnoteFromMarkdown,gfmFootnoteToMarkdown} from 'mdast-util-gfm-footnote';

class FootnoteDefinition extends ElementNode {
  static getType(){return 'projectbook-footnote-definition';}
  static clone(node){return new FootnoteDefinition(node.__id,node.__key);}
  static importJSON(value){return $applyNodeReplacement(new FootnoteDefinition(value.id)).updateFromJSON(value);}
  constructor(id='',key){super(key);this.__id=id;}
  exportJSON(){return {...super.exportJSON(),type:FootnoteDefinition.getType(),version:1,id:this.__id};}
  createDOM(){const el=document.createElement('section');el.className='pb-footnote-definition';el.dataset.footnote=this.__id;return el;}
  updateDOM(){return false;}
  isShadowRoot(){return true;}
}
function Reference({id}){
  const [editor]=useLexicalComposerContext();
  return <sup className="pb-footnote-reference"><button type="button" title="Go to footnote" onClick={()=>editor.update(()=>{
    const definition=$getRoot().getChildren().find(n=>n instanceof FootnoteDefinition && n.__id===id);definition?.selectStart();
  })}>[{id}]</button></sup>;
}
class FootnoteReference extends DecoratorNode {
  static getType(){return 'projectbook-footnote-reference';}
  static clone(node){return new FootnoteReference(node.__id,node.__key);}
  static importJSON(value){return $applyNodeReplacement(new FootnoteReference(value.id));}
  constructor(id='',key){super(key);this.__id=id;}
  exportJSON(){return {...super.exportJSON(),type:FootnoteReference.getType(),version:1,id:this.__id};}
  createDOM(){return document.createElement('span');}
  updateDOM(){return false;}
  isInline(){return true;}
  getTextContent(){return `[^${this.__id}]`;}
  decorate(){return <Reference id={this.__id}/>;}
}
export function InsertFootnote(){
  const editor=useCellValue(activeEditor$),disabled=useCellValue(readOnly$);
  const [open,setOpen]=React.useState(false),[text,setText]=React.useState('');
  const dialog=React.useRef(null),selectionRef=React.useRef(null);
  React.useEffect(()=>{if(open)dialog.current?.showModal();},[open]);
  function close(){dialog.current?.close();setOpen(false);editor?.focus();}
  function insert(){
    if(!text.trim())return;
    editor?.update(()=>{
      if(selectionRef.current)$setSelection(selectionRef.current.clone());
      const selection=$getSelection();if(!$isRangeSelection(selection))return;
      const root=$getRoot(),ids=new Set(root.getChildren().filter(n=>n instanceof FootnoteDefinition).map(n=>n.__id));
      let number=1;while(ids.has(String(number)))number++;
      const id=String(number);selection.insertNodes([$applyNodeReplacement(new FootnoteReference(id))]);
      const saved=$getSelection()?.clone(),definition=$applyNodeReplacement(new FootnoteDefinition(id));
      definition.append($createParagraphNode().append($createTextNode(text.trim())));root.append(definition);if(saved)$setSelection(saved);
    });close();
  }
  return <><button type="button" className="pb-insert-footnote" title="Insert footnote" aria-label="Insert footnote" disabled={disabled} onMouseDown={e=>e.preventDefault()} onClick={()=>{
    editor?.getEditorState().read(()=>{selectionRef.current=$getSelection()?.clone();});setText('');setOpen(true);
  }}><span aria-hidden="true">a<sup>1</sup></span></button>
  {open && createPortal(<dialog ref={dialog} className="pb-footnote-dialog" aria-labelledby="pb-footnote-title" onCancel={()=>setOpen(false)}>
    <h2 id="pb-footnote-title">Insert footnote</h2>
    <form onSubmit={event=>{event.preventDefault();insert();}}>
      <label htmlFor="pb-footnote-text">Footnote text</label>
      <textarea id="pb-footnote-text" autoFocus rows={3} value={text} onChange={event=>setText(event.target.value)}/>
      <p>You can edit the note and format its text at the end of the document.</p>
      <div><button type="button" className="btn" onClick={close}>Cancel</button><button type="submit" className="btn btn-primary" disabled={!text.trim()}>Insert</button></div>
    </form>
  </dialog>,document.body)}</>;
}
export const footnotesPlugin=realmPlugin({init(realm){
  realm.pub(addLexicalNode$,[FootnoteDefinition,FootnoteReference]);
  realm.pub(addSyntaxExtension$,gfmFootnote());realm.pub(addMdastExtension$,gfmFootnoteFromMarkdown());realm.pub(addToMarkdownExtension$,gfmFootnoteToMarkdown());
  realm.pub(addImportVisitor$,[{
    testNode:'footnoteReference',visitNode({mdastNode,lexicalParent}){lexicalParent.append($applyNodeReplacement(new FootnoteReference(mdastNode.identifier)));}
  },{
    testNode:'footnoteDefinition',visitNode({mdastNode,actions}){actions.addAndStepInto($applyNodeReplacement(new FootnoteDefinition(mdastNode.identifier)));}
  }]);
  realm.pub(addExportVisitor$,[{
    testLexicalNode:node=>node instanceof FootnoteReference,visitLexicalNode({lexicalNode,mdastParent,actions}){actions.appendToParent(mdastParent,{type:'footnoteReference',identifier:lexicalNode.__id,label:lexicalNode.__id});}
  },{
    testLexicalNode:node=>node instanceof FootnoteDefinition,visitLexicalNode({lexicalNode,actions}){actions.addAndStepInto('footnoteDefinition',{identifier:lexicalNode.__id,label:lexicalNode.__id});}
  }]);
}});
