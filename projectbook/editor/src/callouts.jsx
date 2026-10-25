import React from 'react';
import {ElementNode,$applyNodeReplacement,$getSelection,$isRangeSelection,$createParagraphNode,$isElementNode,$isRootNode,$setSelection,KEY_ENTER_COMMAND,KEY_BACKSPACE_COMMAND,COMMAND_PRIORITY_HIGH} from 'lexical';
import {$createQuoteNode,$createHeadingNode} from '@lexical/rich-text';
import {realmPlugin,addLexicalNode$,addImportVisitor$,addExportVisitor$,addToMarkdownExtension$,createRootEditorSubscription$,activeEditor$,currentBlockType$,convertSelectionToNode$,Select,readOnly$} from '@mdxeditor/editor';
import {useCellValue,usePublisher} from '@mdxeditor/gurx';
import {calloutTypes,readCallout,calloutMdast,calloutMarkdownExtension} from './callout-format.mjs';
import './callouts.css';

export class CalloutNode extends ElementNode {
  static getType(){return 'projectbook-callout';}
  static clone(node){return new CalloutNode(node.__kind,node.__key);}
  static importJSON(value){return $applyNodeReplacement(new CalloutNode(value.kind)).updateFromJSON(value);}
  constructor(kind='NOTE',key){super(key);this.__kind=Object.hasOwn(calloutTypes,kind)?kind:'NOTE';}
  exportJSON(){return {...super.exportJSON(),type:CalloutNode.getType(),version:1,kind:this.getKind()};}
  getKind(){return this.getLatest().__kind;}
  setKind(kind){this.getWritable().__kind=kind;}
  isShadowRoot(){return true;}
  canBeEmpty(){return false;}
  createDOM(){const el=document.createElement('blockquote');this.decorateDOM(el);return el;}
  decorateDOM(el){el.className='pb-callout pb-callout-'+this.getKind().toLowerCase();el.dataset.callout=this.getKind();el.dataset.label=calloutTypes[this.getKind()];}
  updateDOM(previous,el){if(previous.__kind!==this.__kind)this.decorateDOM(el);return false;}
  exportDOM(){return {element:this.createDOM()};}
  static importDOM(){return {blockquote:el=>Object.hasOwn(calloutTypes,el.dataset.callout)?{priority:2,conversion:()=>({node:$applyNodeReplacement(new CalloutNode(el.dataset.callout))})}:null};}
}
function ancestorCallout(node){while(node && !$isRootNode(node)){if(node instanceof CalloutNode)return node;node=node.getParent();}return null;}
function unwrap(node){const children=node.getChildren();children.forEach(child=>node.insertBefore(child));node.remove();return children;}
function selectedBlocks(selection){
  const nodes=selection.isCollapsed()?[selection.anchor.getNode()]:selection.getNodes();
  const blocks=[];
  for(let node of nodes){
    if($isRootNode(node))continue;
    while(node.getParent() && !$isRootNode(node.getParent()) && !node.getParent().isShadowRoot())node=node.getParent();
    if(!blocks.some(block=>block.is(node)))blocks.push(node);
  }
  return blocks;
}
export function CalloutBlockType(){
  const editor=useCellValue(activeEditor$),blockType=useCellValue(currentBlockType$),readOnly=useCellValue(readOnly$);
  const convert=usePublisher(convertSelectionToNode$);
  const [kind,setKind]=React.useState('');
  React.useEffect(()=>{
    if(!editor)return;
    const update=({editorState})=>editorState.read(()=>{const s=$getSelection();setKind($isRangeSelection(s)?ancestorCallout(s.anchor.getNode())?.getKind()||'':'');});
    update({editorState:editor.getEditorState()});return editor.registerUpdateListener(update);
  },[editor]);
  function change(value){
    if(Object.hasOwn(calloutTypes,value)){
      editor?.update(()=>{
        const selection=$getSelection();if(!$isRangeSelection(selection))return;
        const current=ancestorCallout(selection.anchor.getNode());
        if(current && ancestorCallout(selection.focus.getNode()) && current.is(ancestorCallout(selection.focus.getNode()))){current.setKind(value);return;}
        const blocks=selectedBlocks(selection);if(!blocks.length)return;
        const saved=selection.clone(),container=$applyNodeReplacement(new CalloutNode(value));
        blocks[0].insertBefore(container);
        blocks.forEach(block=>{
          if(block instanceof CalloutNode || block.getType()==='quote'){
            const children=block.getChildren();
            if(children.every(child=>$isElementNode(child)&&!child.isInline()))container.append(...children);
            else container.append($createParagraphNode().append(...children));
            block.remove();
          } else container.append(block);
        });
        $setSelection(saved);
      });
    } else if(kind){
      editor?.update(()=>{
        const selection=$getSelection();if(!$isRangeSelection(selection))return;
        const callout=ancestorCallout(selection.anchor.getNode());if(!callout)return;
        const saved=selection.clone(),children=unwrap(callout);
        if(value==='quote'){
          const quote=$createQuoteNode();children[0].insertBefore(quote);quote.append(...children);
        } else if(value.startsWith('h')){
          for(const child of children)if(child.getType()==='paragraph'){const heading=$createHeadingNode(value);heading.append(...child.getChildren());child.replace(heading);}
        }
        $setSelection(saved);
      });
    } else convert(()=>value==='quote'?$createQuoteNode():value==='paragraph'?$createParagraphNode():$createHeadingNode(value));
    setTimeout(()=>editor?.focus(),0);
  }
  return <Select value={kind||blockType} onChange={change} disabled={readOnly} triggerTitle="Choose paragraph, heading, quote or callout" placeholder="Block type"
    items={[{value:'paragraph',label:'Paragraph'},{value:'quote',label:'Quote'},...[1,2,3,4,5,6].map(n=>({value:'h'+n,label:'Heading '+n})),...Object.entries(calloutTypes).map(([value,label])=>({value,label}))]}/>;
}
export const calloutsPlugin=realmPlugin({init(realm){
  realm.pub(addLexicalNode$,CalloutNode);
  realm.pub(addToMarkdownExtension$,calloutMarkdownExtension);
  realm.pub(addImportVisitor$,{
    priority:60,testNode:node=>!!readCallout(node),
    visitNode({mdastNode,lexicalParent,actions}){
      const value=readCallout(mdastNode),node=$applyNodeReplacement(new CalloutNode(value.kind));lexicalParent.append(node);
      actions.visitChildren({type:'root',children:value.children},node);
      if(node.isEmpty())node.append($createParagraphNode());
    }
  });
  realm.pub(addExportVisitor$,{
    priority:60,testLexicalNode:node=>node instanceof CalloutNode,
    visitLexicalNode({lexicalNode,mdastParent,actions}){
      const node=calloutMdast(lexicalNode.getKind());actions.appendToParent(mdastParent,node);actions.visitChildren(lexicalNode,node);
    }
  });
  realm.pub(createRootEditorSubscription$,editor=>{
    const enter=editor.registerCommand(KEY_ENTER_COMMAND,event=>{
      const selection=$getSelection();if(!$isRangeSelection(selection)||!selection.isCollapsed())return false;
      let paragraph=selection.anchor.getNode();if(!$isElementNode(paragraph))paragraph=paragraph.getParent();
      const callout=paragraph?.getParent();
      if(!(callout instanceof CalloutNode)||paragraph.getType()!=='paragraph'||paragraph.getTextContent()!==''||!paragraph.is(callout.getLastChild()))return false;
      const outside=$createParagraphNode();callout.insertAfter(outside);paragraph.remove();if(callout.isEmpty())callout.remove();outside.selectStart();event?.preventDefault();return true;
    },COMMAND_PRIORITY_HIGH);
    const back=editor.registerCommand(KEY_BACKSPACE_COMMAND,event=>{
      const selection=$getSelection();if(!$isRangeSelection(selection)||!selection.isCollapsed()||selection.anchor.offset!==0)return false;
      const callout=ancestorCallout(selection.anchor.getNode());if(!callout)return false;
      const first=callout.getFirstDescendant()||callout.getFirstChild();if(!first?.is(selection.anchor.getNode()))return false;
      const saved=selection.clone();unwrap(callout);$setSelection(saved);event?.preventDefault();return true;
    },COMMAND_PRIORITY_HIGH);
    return ()=>{enter();back();};
  });
}});
