import React, {useEffect,useRef,useState} from 'react';
import {createRoot} from 'react-dom/client';
import {draftStore} from './drafts.js';
import './raw-notes.css';
const base=window.baseUrl||'';
const endpoint=base+'/gollum/projectbook/raw-notes';
async function api(action,body){
 const response=await fetch(endpoint+(action?'/'+action:''),body?{method:'POST',headers:{'Content-Type':'application/json','X-ProjectWiki-Request':'1'},body:JSON.stringify(body)}:{cache:'no-store'});
 let data;try{data=await response.json();}catch{throw Error('Server request failed (HTTP '+response.status+'). Retry after the server is available.');}if(!response.ok)throw Error(data.error||'Request failed');return data;
}
const makeDraft=()=>({id:crypto.randomUUID(),title:'',text:'',files:[]});

const bytes64=bytes=>{let result='';for(let i=0;i<bytes.length;i++)result+=String.fromCharCode(bytes[i]);return btoa(result);};
function Media({item}){
 const [url,setURL]=useState('');useEffect(()=>{const value=URL.createObjectURL(item.blob);setURL(value);return()=>URL.revokeObjectURL(value);},[item.blob]);
 return item.mime_type.startsWith('image/')?<img src={url} alt={item.name}/>:item.mime_type.startsWith('audio/')?<audio src={url} controls preload="metadata"/>:<a href={url} download={item.name}>📄 {item.name}</a>;
}
async function photo(file,original){
 if(original||!file.type.startsWith('image/'))return {blob:file,name:file.name,mime_type:file.type};
 let url=URL.createObjectURL(file);
 try{
  const img=new Image();img.src=url;await img.decode();
  const scale=Math.min(1,2048/Math.max(img.width,img.height));const canvas=document.createElement('canvas');canvas.width=Math.round(img.width*scale);canvas.height=Math.round(img.height*scale);
  const ctx=canvas.getContext('2d');ctx.fillStyle='#fff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(img,0,0,canvas.width,canvas.height);
  const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',.85));if(!blob)throw Error('Encoding failed');
  return {blob,name:file.name.replace(/\.[^.]+$/,'')+'.jpg',mime_type:'image/jpeg'};
 }catch{return {blob:file,name:file.name,mime_type:file.type||(/\.heic$/i.test(file.name)?'image/heic':''),warning:'Could not resize; keeping the original.'};}
 finally{URL.revokeObjectURL(url);}
}
function RecordingStatus({stream}){
 const [elapsed,setElapsed]=useState(0),[levels,setLevels]=useState(()=>Array(48).fill(0)),[meterError,setMeterError]=useState(false);
 useEffect(()=>{const started=Date.now();let context,analyser,samples;
  try{const AudioContext=window.AudioContext||window.webkitAudioContext;context=new AudioContext();analyser=context.createAnalyser();analyser.fftSize=256;samples=new Uint8Array(analyser.fftSize);context.createMediaStreamSource(stream).connect(analyser);void context.resume().catch(()=>setMeterError(true));}catch{setMeterError(true);}
  const timer=setInterval(()=>{setElapsed(Math.floor((Date.now()-started)/1000));if(analyser){analyser.getByteTimeDomainData(samples);const rms=Math.sqrt(samples.reduce((n,v)=>n+((v-128)/128)**2,0)/samples.length);setLevels(previous=>[...previous.slice(1),Math.min(1,rms*5)]);}},100);
  return()=>{clearInterval(timer);void context?.close().catch(()=>{});};
 },[stream]);
 return <div className="raw-recording" role="region" aria-label="Voice recording"><span className="raw-recording-dot" aria-hidden="true"/><strong>Recording</strong><time aria-label="Recording duration">{String(Math.floor(elapsed/60)).padStart(2,'0')}:{String(elapsed%60).padStart(2,'0')}</time><div className="raw-waveform" role="img" aria-label="Live microphone sound history">{levels.map((value,index)=><i key={index} style={{height:Math.max(3,Math.round(value*44))+'px'}}/>)}</div><span>{meterError?'Sound visualization unavailable; recording is still active':'Speak to see the sound move'}</span></div>;
}
const mediaURL=path=>base+'/gollum/projectbook/raw-notes-media/'+path.split('/').map(encodeURIComponent).join('/');
function SavedMedia({file}){return file.mime_type.startsWith('image/')?<img loading="lazy" src={mediaURL(file.path)} alt={file.name}/>:file.mime_type.startsWith('audio/')?<audio controls preload="none" src={mediaURL(file.path)}/>:<a href={mediaURL(file.path)}>📄 {file.name}</a>;}
function Capture({noteId=''}){
 const keyRef=useRef(base+':raw-chat:'+(noteId||'new'));const key=keyRef.current;
 const [draft,setDraft]=useState(()=>({id:noteId||crypto.randomUUID(),text:'',queue:[]})),[ready,setReady]=useState(false),[note,setNote]=useState(null),[notice,setNotice]=useState(''),[progress,setProgress]=useState(''),[busy,setBusy]=useState(false),[recording,setRecording]=useState(false),[starting,setStarting]=useState(false),[editing,setEditing]=useState(null);
 const latest=useRef(draft),current=useRef(null),running=useRef(false),recorder=useRef(null),stream=useRef(null),cancelRecording=useRef(false),request=useRef(0),persistQueue=useRef(Promise.resolve()),bottom=useRef(null),input=useRef(null);
 latest.current=draft;
 function change(next){latest.current=next;setDraft(next);const targetKey=keyRef.current;persistQueue.current=persistQueue.current.catch(()=>{}).then(()=>draftStore('put',targetKey,next)).catch(()=>setNotice('Device draft storage unavailable. Keep this tab open until uploads finish.'));}
 useEffect(()=>{let active=true;(async()=>{try{const saved=await draftStore('get',key);if(active&&saved){latest.current=saved;setDraft(saved);}if(noteId){const n=await api(noteId);if(active){current.current=n;setNote(n);}}else if(saved?.created){const n=await api(saved.id);if(active){current.current=n;setNote(n);}}}catch(e){if(active)setNotice(e.message);}finally{if(active)setReady(true);}})();return()=>{active=false;request.current++;cancelRecording.current=true;if(recorder.current?.state==='recording')recorder.current.stop();stream.current?.getTracks().forEach(t=>t.stop());};},[]);
 useEffect(()=>{function warn(e){if(recording||starting||running.current||latest.current.queue.length||latest.current.text.trim()){e.preventDefault();e.returnValue='';}}window.addEventListener('beforeunload',warn);return()=>window.removeEventListener('beforeunload',warn);},[recording,starting]);
 useEffect(()=>{bottom.current?.scrollIntoView({block:'nearest'});},[note?.document_version,draft.queue.length]);
 useEffect(()=>{if(input.current){input.current.style.height='auto';input.current.style.height=Math.min(140,input.current.scrollHeight)+'px';}},[draft.text]);
 function enqueue(message){change({...latest.current,queue:[...latest.current.queue,{id:crypto.randomUUID(),text:'',files:[],...message}]});void drain();}
 async function drain(){
  if(running.current)return;running.current=true;setBusy(true);setNotice('');
  try{while(latest.current.queue.length){const message=latest.current.queue[0];await persistQueue.current;
    const attachments=[];
    for(let n=0;n<message.files.length;n++){const f=message.files[n],bytes=new Uint8Array(await f.blob.arrayBuffer());const sha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
      for(let offset=0;offset<bytes.length;offset+=262144){setProgress(`Uploading ${f.name} · ${Math.round(offset/bytes.length*100)}%`);let error;for(let attempt=0;attempt<3;attempt++){try{await api('upload',{upload_id:f.upload_id,offset,data:bytes64(bytes.slice(offset,offset+262144))});error=null;break;}catch(e){error=e;}}if(error)throw error;}
      attachments.push({upload_id:f.upload_id,name:f.name,mime_type:f.mime_type,sha256});}
    setProgress('Saving message…');
    // Refresh only before append; retry IDs prevent duplication after a lost response.
    const existing=current.current?await api(current.current.id):null;
    const result=existing?await api('append',{id:existing.id,message_id:message.id,expected_version:existing.document_version,text:message.text,attachments}):await api('create',{id:latest.current.id,text:message.text,attachments});
    current.current=result;
    const detail=await api(result.id);current.current=detail;setNote(detail);
    if(!existing){await persistQueue.current;const oldKey=keyRef.current;keyRef.current=base+':raw-chat:'+result.id;await draftStore('delete',oldKey).catch(()=>{});}
    const next={...latest.current,created:true,queue:latest.current.queue.filter(m=>m.id!==message.id)};latest.current=next;setDraft(next);await draftStore('put',keyRef.current,next).catch(()=>{});
    history.replaceState(null,'',base+'/gollum/raw-notes/'+result.id);
   }setProgress('Saved on server');
  }catch(e){setNotice(e.message+' Retry the pending message.');setProgress('Upload paused');}finally{running.current=false;setBusy(false);}
 }
 async function addFiles(event){const files=Array.from(event.target.files||[]);event.target.value='';for(const f of files){try{setProgress('Preparing '+f.name+'…');const item=await photo(f,false);if(!item.blob.size||item.blob.size>20*1024*1024)throw Error('Use files between 1 byte and 20 MiB.');enqueue({files:[{...item,upload_id:crypto.randomUUID()}]});}catch(e){setNotice(e.message);}}}
 function sendText(){const text=latest.current.text;if(!text.trim())return;change({...latest.current,text:''});enqueue({text});}
 async function record(){
  if(starting){request.current++;setStarting(false);return;}
  if(recording){if(recorder.current?.state==='recording')recorder.current.stop();return;}
  if(!navigator.mediaDevices?.getUserMedia||!window.MediaRecorder){setNotice('Voice recording requires HTTPS and microphone support.');return;}
  const attempt=++request.current;setStarting(true);cancelRecording.current=false;
  try{const media=await navigator.mediaDevices.getUserMedia({audio:true});if(attempt!==request.current){media.getTracks().forEach(t=>t.stop());return;}stream.current=media;
   const mime=['audio/mp4','audio/webm;codecs=opus','audio/webm','audio/ogg;codecs=opus'].find(t=>MediaRecorder.isTypeSupported(t));const rec=new MediaRecorder(media,mime?{mimeType:mime}:undefined);recorder.current=rec;const parts=[];let size=0;
   rec.ondataavailable=e=>{if(e.data.size){parts.push(e.data);size+=e.data.size;if(size>=18*1024*1024&&rec.state==='recording')rec.stop();}};
   rec.onerror=()=>{cancelRecording.current=true;setNotice('Recording failed. Please try again.');media.getTracks().forEach(t=>t.stop());setRecording(false);};
   rec.onstop=()=>{media.getTracks().forEach(t=>t.stop());setRecording(false);if(cancelRecording.current)return;const type=rec.mimeType.split(';')[0],blob=new Blob(parts,{type});if(!blob.size||blob.size>20*1024*1024){setNotice('Recording is empty or exceeds 20 MiB.');return;}enqueue({files:[{blob,name:'Voice recording',mime_type:type,upload_id:crypto.randomUUID()}]});};
   rec.start(1000);setRecording(true);
  }catch(e){setNotice(e.message);stream.current?.getTracks().forEach(t=>t.stop());}finally{if(attempt===request.current)setStarting(false);}
 }
 function cancelVoice(){cancelRecording.current=true;if(recorder.current?.state==='recording')recorder.current.stop();}
 async function editMessage(message,remove=false){if(remove&&!confirm('Delete this message from the note?'))return;try{const result=await api('edit-message',{id:note.id,index:message.index,expected_version:note.document_version,text:editing?.text,delete:remove});setNote(result);current.current=result;setEditing(null);}catch(e){setNotice(e.message);}}
 function close(){if((recording||starting||busy||draft.queue.length||draft.text.trim())&&!confirm('Close this note? Pending uploads may stop; unsent messages stay on this device.'))return;location.href=base+'/gollum/raw-notes';}
 if(!ready)return <p>Opening note…</p>;
 return <section className="raw-chat-screen">
  <header className="raw-chat-header"><button className="btn" onClick={close} aria-label="Close note">‹</button><h1>{note?.title||'New note'}</h1><span>{note?.storage==='local'?'This deployment':note?'Git':''}</span></header>
  <div className="raw-chat-feed" aria-label="Note messages">
   {note?.messages?.map(message=><article className="raw-chat-bubble" key={message.index}>
    {editing?.index===message.index?<div><textarea aria-label="Edit message" value={editing.text} onChange={e=>setEditing({...editing,text:e.target.value})}/><button className="btn" onClick={()=>editMessage(message)}>Save</button><button className="btn" onClick={()=>setEditing(null)}>Cancel</button></div>:message.text&&<p onClick={()=>setEditing({index:message.index,text:message.text})}>{message.text}</p>}
    {message.attachments.map(file=><SavedMedia key={file.path} file={file}/>)}
    <div className="raw-message-tools"><button title="Edit message text" aria-label="Edit message text" onClick={()=>setEditing({index:message.index,text:message.text})}>✎</button><button title="Delete message" aria-label="Delete message" onClick={()=>editMessage(message,true)}>×</button></div>
   </article>)}
   {draft.queue.map((m,i)=><article className="raw-chat-bubble raw-pending" key={m.id}><p>{m.text}</p>{m.files.map(f=><Media key={f.upload_id} item={f}/>)}<small>{i===0?progress:'Waiting to upload'}</small>{!busy&&<button className="btn" onClick={()=>change({...latest.current,queue:latest.current.queue.filter(q=>q.id!==m.id)})}>Remove</button>}</article>)}
   {!note&&!draft.queue.length&&<p className="raw-empty-chat">Add a photo, record your voice or write a message.</p>}<div ref={bottom}/>
  </div>
  <footer className="raw-chat-footer">
   {recording&&<RecordingStatus stream={stream.current}/>}
   <div className="raw-chat-input">
    {recording?<button className="raw-chat-icon" aria-label="Cancel recording" onClick={cancelVoice}>×</button>:draft.text?<button className="raw-chat-icon" aria-label="Clear text" onClick={()=>change({...latest.current,text:''})}>×</button>:<label className="raw-chat-icon raw-picker" title="Add attachment">＋<input aria-label="Add attachment" type="file" accept="image/*,audio/*,.m4a,.mp3,.wav,.ogg,.webm,.pdf,.txt,.docx" multiple onChange={addFiles}/></label>}
    <textarea ref={input} rows={1} aria-label="Message" placeholder="Message…" value={draft.text} onChange={e=>change({...latest.current,text:e.target.value})}/>
    {recording?<button className="raw-chat-icon" aria-label="Stop and send recording" onClick={record}>■</button>:draft.text.trim()?<button className="raw-chat-icon" aria-label="Send text" onClick={sendText}>↑</button>:<button className="raw-chat-icon" aria-label={starting?'Cancel microphone request':'Record voice'} onClick={record}>{starting?'×':<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10v2a7 7 0 0014 0v-2M12 19v3M8 22h8"/></svg>}</button>}
   </div>
   <p role="status">{notice||progress}</p>{notice&&draft.queue.length>0&&!busy&&<button className="btn" onClick={drain}>Retry upload</button>}
  </footer>
 </section>;
}
function Inbox(){
 const [items,setItems]=useState([]),[filter,setFilter]=useState('unsorted'),[error,setError]=useState(''),[editable,setEditable]=useState(false);
 async function load(){try{const data=await api();setItems(data.items);setEditable(data.editable);}catch(e){setError(e.message);}}
 useEffect(()=>{load();},[]);
 async function status(item){try{await api('status',{id:item.id,expected_version:item.version,status:item.status==='processed'?'unsorted':'processed',results:item.results});await load();}catch(e){setError(e.message);}}
 const filtered=items.filter(n=>filter==='all'||n.status===filter);
 return <section className="raw-inbox">
  <div className="raw-heading"><h1>Raw Notes</h1></div>
  <div className="raw-tools" role="group" aria-label="Note status">{['unsorted','processed','all'].map(value=><button className="btn" aria-pressed={value===filter} key={value} onClick={()=>setFilter(value)}>{value[0].toUpperCase()+value.slice(1)}</button>)}</div>
  <p className="raw-hint">Newest notes first</p><p role="status">{error}</p>
  {filtered.map(note=><article key={note.id}>
   <header><h2><a href={note.url}>{note.title}</a></h2><time dateTime={note.created_at}>{new Date(note.created_at).toLocaleString()}</time></header>
   {note.excerpt&&<p className="raw-excerpt">{note.excerpt}</p>}
   <div className="raw-gallery">{note.attachments.filter(f=>f.mime_type.startsWith('image/')).slice(0,4).map(f=><a key={f.path} href={note.url} aria-label={'Open '+note.title}><img loading="lazy" alt={f.name} src={mediaURL(f.path)}/></a>)}</div>
   {note.attachments.filter(f=>f.mime_type.startsWith('audio/')).map(f=><audio key={f.path} aria-label={f.name} src={mediaURL(f.path)} controls preload="none"/>)}
   <footer><a href={note.url}>Open note{note.attachments.length?' · '+note.attachments.length+' attachments':''}</a>{editable&&<button className="btn" onClick={()=>status(note)}>{note.status==='processed'?'Return to Unsorted':'Mark processed'}</button>}</footer>
  </article>)}
  {!filtered.length&&<p>No {filter==='all'?'':filter} notes yet.</p>}
  {editable&&<a className="btn btn-primary raw-new" href={base+'/gollum/raw-notes/new'}>＋ New raw note</a>}
 </section>;
}
const mount=document.getElementById('projectbook-raw-notes');
const chatID=location.pathname.match(/\/gollum\/raw-notes\/([0-9a-f-]{36})$/)?.[1];
if(mount){const chat=location.pathname.endsWith('/new')||chatID;if(chat)document.body.classList.add('raw-chat-page');createRoot(mount).render(chat?<Capture noteId={chatID||''}/>:<Inbox/>);}
const legacy=location.pathname.slice(base.length).match(/^\/raw-notes\/\d{4}-\d{2}-\d{2}-([0-9a-f-]{36})\/note(?:\.md)?$/);
if(legacy)location.replace(base+'/gollum/raw-notes/'+legacy[1]);
