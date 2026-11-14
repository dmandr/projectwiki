import React from 'react';
import {useCellValue} from '@mdxeditor/gurx';
import {viewMode$} from '@mdxeditor/editor';
export function InlineTodoToolbar({onNew,onTags,onList,onError}){
  const mode=useCellValue(viewMode$);
  const action=fn=>async()=>{try{await fn();}catch(e){onError(e.message);}};
  return <span className="pb-todo-editor-tools" role="group" aria-label="TODO tools">
    <button type="button" title="New TODO from selection" aria-label="New TODO" disabled={mode==='diff'} onMouseDown={e=>e.preventDefault()} onClick={action(onNew)}><svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.7"><rect x="3" y="4" width="12" height="16" rx="2"/><path d="m5 10 3 3 5-6m5 4v8m-4-4h8"/></svg></button>
    <button type="button" title="Edit tags of selected TODOs" aria-label="Edit TODO tags" disabled={mode==='diff'} onMouseDown={e=>e.preventDefault()} onClick={action(onTags)}><svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.7"><path d="M3 3h9l9 9-9 9-9-9Z"/><circle cx="8" cy="8" r="1"/></svg></button>
    <button type="button" title="Insert TODO list" aria-label="Insert TODO list" disabled={mode==='diff'} onMouseDown={e=>e.preventDefault()} onClick={action(onList)}><svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.7"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M6 7h2m3 0h7M6 12h2m3 0h7M6 17h2m3 0h7"/></svg></button>
  </span>;
}
