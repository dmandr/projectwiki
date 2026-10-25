import React from 'react';
import {createPortal} from 'react-dom';
import {useCellValue,usePublisher} from '@mdxeditor/gurx';
import {viewMode$} from '@mdxeditor/editor';

const modes=[['rich-text','Visual'],['diff','Changes'],['source','Markdown']];
export function EditorToolbar({children,sourceTools}) {
  const mode=useCellValue(viewMode$),changeMode=usePublisher(viewMode$);
  const [target,setTarget]=React.useState(null);
  React.useEffect(()=>{setTarget(document.getElementById('projectbook-editor-modes'));},[]);
  return <>
    {target && createPortal(<span className="pb-editor-modes" role="radiogroup" aria-label="Editor mode">
      {modes.map(([value,label],index)=><button type="button" key={value} role="radio" aria-checked={mode===value}
        tabIndex={mode===value?0:-1} title={label} onClick={()=>changeMode(value)} onKeyDown={event=>{
          if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
          event.preventDefault();
          const next=event.key==='Home'?0:event.key==='End'?modes.length-1:(index+(event.key==='ArrowLeft'?-1:1)+modes.length)%modes.length;
          changeMode(modes[next][0]);event.currentTarget.parentElement.children[next].focus();
        }}>{label}</button>)}
    </span>,target)}
    {mode==='rich-text'?children:mode==='source'?sourceTools:<span>Changes</span>}
  </>;
}
