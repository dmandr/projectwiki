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
function Capture({noteId=''}){
 const key=base+':raw-note'+(noteId?':'+noteId:'');
 const [note,setNote]=useState(null),[loadError,setLoadError]=useState('');
 useEffect(()=>{if(noteId)api(noteId).then(setNote).catch(e=>setLoadError(e.message));},[noteId]);
 const [draft,setDraft]=useState(makeDraft),[ready,setReady]=useState(false),[notice,setNotice]=useState(''),[busy,setBusy]=useState(false),[recording,setRecording]=useState(false),[original,setOriginal]=useState(false),[local,setLocal]=useState('');
 const [menu,setMenu]=useState(false),[starting,setStarting]=useState(false);
 const microphoneRequest=useRef(0),sendRecording=useRef(false);
 const recorder=useRef(),stream=useRef(),saveQueue=useRef(Promise.resolve()),saved=useRef(false),latest=useRef(draft);latest.current=draft;
 useEffect(()=>{draftStore('get',key).then(d=>{if(d){setDraft(d);setNotice('Restored your local draft.');}}).catch(()=>setLocal('Browser draft storage is unavailable. Keep this tab open.')).finally(()=>setReady(true));return()=>{microphoneRequest.current++;if(recorder.current?.state==='recording')recorder.current.stop();stream.current?.getTracks().forEach(t=>t.stop());};},[]);
 useEffect(()=>{if(!ready||saved.current)return;saveQueue.current=saveQueue.current.catch(()=>{}).then(()=>draftStore('put',key,draft)).then(()=>setLocal('Unsent message saved on this device')).catch(()=>setLocal('Draft could not be stored. Keep this tab open.'));},[draft,ready]);
 useEffect(()=>{const warn=e=>{if(!saved.current&&(latest.current.text||latest.current.files.length||recorder.current?.state==='recording')){e.preventDefault();e.returnValue='';}};window.addEventListener('beforeunload',warn);return()=>window.removeEventListener('beforeunload',warn);},[]);
 function append(item){if(item.blob.size>20*1024*1024){setNotice('File exceeds 20 MiB. Choose a smaller file.');return;}setDraft(d=>({...d,files:[...d.files,{...item,upload_id:crypto.randomUUID()}]}));}
 async function addFiles(event){const files=[...event.target.files];event.target.value='';setMenu(false);setBusy(true);setNotice('Preparing attachments…');try{for(const file of files){const audioTypes={m4a:'audio/mp4',mp3:'audio/mpeg',wav:'audio/wav',ogg:'audio/ogg',webm:'audio/webm'};const type=file.type||({pdf:'application/pdf',txt:'text/plain',docx:'application/vnd.openxmlformats-officedocument.wordprocessingml.document'}[file.name.split('.').pop().toLowerCase()])||audioTypes[file.name.split('.').pop().toLowerCase()]||'';if(!/^(image|audio)\//.test(type)&&!['application/pdf','text/plain','application/vnd.openxmlformats-officedocument.wordprocessingml.document'].includes(type)&&!(/\.heic$/i.test(file.name)))throw Error('Use photos, audio, PDF, TXT or DOCX. Video is not supported yet.');append(await photo(type!==file.type?new File([file],file.name,{type}):file,original));}setNotice('');}catch(e){setNotice(e.message);}finally{setBusy(false);}}
 async function record(){
 if(recording){recorder.current.stop();return;}
 if(starting){microphoneRequest.current++;setStarting(false);setNotice('Microphone request canceled.');return;}const attempt=++microphoneRequest.current;setStarting(true);setMenu(false);setNotice('Waiting for microphone permission…');
 try{
  if(!navigator.mediaDevices?.getUserMedia||!window.MediaRecorder)throw Error('Voice recording requires HTTPS (or localhost) and a supported browser. You can also attach an audio file.');
  const media=await navigator.mediaDevices.getUserMedia({audio:true});
  if(attempt!==microphoneRequest.current){media.getTracks().forEach(t=>t.stop());return;}stream.current=media;
  const mime=['audio/mp4','audio/webm;codecs=opus','audio/webm','audio/ogg;codecs=opus'].find(t=>MediaRecorder.isTypeSupported(t));
  const rec=new MediaRecorder(stream.current,mime?{mimeType:mime}:undefined);recorder.current=rec;let parts=[],size=0;
  rec.ondataavailable=e=>{if(e.data.size){parts.push(e.data);size+=e.data.size;if(size>=18*1024*1024&&rec.state==='recording'){rec.stop();setNotice('Recording stopped at the size limit.');}}};
  rec.onerror=()=>{sendRecording.current=false;setBusy(false);setNotice('Recording was interrupted. Check the recorded clip before saving.');stream.current?.getTracks().forEach(t=>t.stop());setRecording(false);};
  rec.onstop=()=>{
   stream.current?.getTracks().forEach(t=>t.stop());setRecording(false);
   const sendNow=sendRecording.current;sendRecording.current=false;
   const type=rec.mimeType.split(';')[0],blob=new Blob(parts,{type});
   if(!blob.size || blob.size>20*1024*1024){setBusy(false);setNotice(blob.size?'Recording exceeds 20 MiB. Please record a shorter clip.':'No audio was captured. Try recording again.');return;}
   const next={...latest.current,files:[...latest.current.files,{blob,name:'Voice recording',mime_type:type,upload_id:crypto.randomUUID()}]};
   latest.current=next;setDraft(next);
   setNotice('Recording added. You can listen before sending.');
   if(sendNow)void save(next);
  };
  rec.start(1000);setRecording(true);setNotice('Recording… keep this page open until you stop.');
 }catch(e){if(attempt===microphoneRequest.current){stream.current?.getTracks().forEach(t=>t.stop());setNotice(e.message);}}finally{if(attempt===microphoneRequest.current)setStarting(false);}
 }
 function send(){if(busy)return;if(recording){sendRecording.current=true;setBusy(true);setNotice('Finishing recording…');if(recorder.current?.state==='recording')recorder.current.stop();}else void save();}
 async function save(message=latest.current){setBusy(true);setNotice('Uploading…');try{
  await saveQueue.current.catch(()=>{});await draftStore('put',key,message).catch(()=>setLocal('Draft could not be stored. Keep this tab open.'));
  if(message.files.length>20||message.files.reduce((n,f)=>n+f.blob.size,0)>50*1024*1024)throw Error('Use at most 20 files and 50 MiB per note.');
  const attachments=[];
  for(let n=0;n<message.files.length;n++){
   const f=message.files[n],bytes=new Uint8Array(await f.blob.arrayBuffer());
   const sha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
   for(let offset=0;offset<bytes.length;offset+=262144){setNotice(`Uploading ${n+1}/${message.files.length} · ${Math.round(offset/bytes.length*100)}%`);let error;for(let attempt=0;attempt<3;attempt++){try{await api('upload',{upload_id:f.upload_id,offset,data:bytes64(bytes.slice(offset,offset+262144))});error=null;break;}catch(e){error=e;}}if(error)throw error;}
   attachments.push({upload_id:f.upload_id,name:f.name,mime_type:f.mime_type,sha256});
  }
  setNotice('Saving note and attachments to the book…');const result=noteId?await api('append',{id:noteId,message_id:message.id,expected_version:note.document_version,text:message.text,attachments}):await api('create',{id:message.id,title:message.title,text:message.text,attachments});saved.current=true;await saveQueue.current;await draftStore('delete',key);if(noteId){location.hash='raw-note-compose';location.reload();}else location.href=result.url+'#raw-note-compose';
 }catch(e){setNotice(e.message+' Your draft is kept; you can retry.');}finally{setBusy(false);}}
 useEffect(()=>{if(ready&&(!noteId||note)&&location.hash==='#raw-note-compose')document.getElementById('raw-note-compose')?.scrollIntoView({block:'end'});},[ready,note]);
 if(loadError)return <p role="alert">{loadError}</p>;
 if(!ready||(noteId&&!note))return <p>Restoring draft…</p>;
 if(noteId&&!note.editable)return null;
 return <section className={"raw-capture raw-chat-compose"+(noteId?'':' raw-chat-new')} id="raw-note-compose">
  <div className="raw-heading">{!noteId&&<h1>New raw note</h1>}<a href={base+'/gollum/raw-notes'}>Raw Notes</a></div>
  {!noteId&&<p>Send text, photos or voice. Continue this note whenever you return.</p>}
  <fieldset disabled={busy}>
   {!noteId&&<label>Title <span>(optional)</span><input value={draft.title} maxLength={200} placeholder="Date and time if left blank" onChange={e=>setDraft({...draft,title:e.target.value})}/></label>}
   <div className="raw-media" aria-label="Attachments for the next message">{draft.files.map(f=><figure key={f.upload_id}><Media item={f}/><figcaption>{f.name} · {(f.blob.size/1024).toFixed(0)} KiB {f.warning&&<span>{f.warning}</span>}</figcaption><button type="button" className="btn" aria-label={'Remove '+f.name} onClick={()=>setDraft(d=>({...d,files:d.files.filter(a=>a.upload_id!==f.upload_id)}))}>Remove</button></figure>)}</div>
   <div className="raw-add raw-composer-box">
    {recording&&<RecordingStatus stream={stream.current}/>}
    <label className="raw-text-label"><span className="raw-sr-only">Message</span><textarea rows={3} value={draft.text} placeholder="Message…" onChange={e=>setDraft({...draft,text:e.target.value})}/></label>
    {menu&&<div className="raw-attachment-menu" role="group" aria-label="Add attachment">
     <label className="btn">Camera<input aria-label="Take photo" type="file" accept="image/*" capture="environment" onChange={addFiles}/></label>
     <label className="btn">Photos<input aria-label="Photo library" type="file" accept="image/*" multiple onChange={addFiles}/></label>
     <label className="btn">Files<input aria-label="Add files" type="file" accept="image/*,audio/*,.m4a,.mp3,.wav,.ogg,.webm,.pdf,.txt,.docx" multiple onChange={addFiles}/></label>
     <label className="raw-original"><input type="checkbox" checked={original} onChange={e=>setOriginal(e.target.checked)}/> Keep original photos</label>
     <small>Photos resize to 2048 px by default. Video is not supported yet.</small>
    </div>}
    <div className="raw-composer-actions">
     <button type="button" className="btn raw-icon" title="Add photos or files" aria-label="Add attachment" aria-expanded={menu} onClick={()=>setMenu(!menu)}>＋</button>
     <button type="button" className={'btn raw-record-button'+(recording?' is-recording':'')} aria-pressed={recording} onClick={record} title={recording?'Stop recording':'Record voice'}>{starting?'Cancel microphone request':recording?'■ Stop':'● Record'}</button>
     <button type="button" className="btn btn-primary raw-save" disabled={starting||(!recording&&!draft.text.trim()&&!draft.files.length)} onClick={send}>{busy?'Sending…':'Send ↑'}</button>
    </div>
   </div>
  </fieldset><p className="raw-local">{local}</p><p role="status" aria-live="polite">{notice}</p>
 </section>;
}
function Inbox(){
 const [items,setItems]=useState([]),[filter,setFilter]=useState('unsorted'),[error,setError]=useState(''),[editable,setEditable]=useState(false);
 async function load(){try{const data=await api();setItems(data.items);setEditable(data.editable);}catch(e){setError(e.message);}}
 useEffect(()=>{load();},[]);
 async function status(item){try{await api('status',{id:item.id,expected_version:item.version,status:item.status==='processed'?'unsorted':'processed',results:item.results});await load();}catch(e){setError(e.message);}}
 const mediaURL=path=>base+'/'+path.split('/').map(encodeURIComponent).join('/');
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
const mount=document.getElementById('projectbook-raw-notes');if(mount)createRoot(mount).render(location.pathname.endsWith('/new')?<Capture/>:<Inbox/>);
// Keep ordinary Markdown download links; add a native player beside audio links.
const noteMatch=location.pathname.slice(base.length).match(/^\/raw-notes\/\d{4}-\d{2}-\d{2}-([0-9a-f-]{36})\/note(?:\.md)?$/);
if(noteMatch){const content=document.querySelector('#wiki-content')||document.querySelector('.markdown-body')?.parentElement;if(content){const composer=document.createElement('div');content.append(composer);createRoot(composer).render(<Capture noteId={noteMatch[1]}/>);document.body.classList.add('raw-note-chat');}}
if(location.pathname.includes('/raw-notes/'))document.querySelectorAll('.markdown-body a').forEach(link=>{const url=new URL(link.href,location.href);if(url.origin===location.origin&&/\/media\/voice-[0-9a-f-]+\.(m4a|mp3|webm|ogg|wav)$/.test(url.pathname)){const audio=document.createElement('audio');audio.controls=true;audio.preload='metadata';audio.src=base+'/'+url.pathname.replace(/^.*?(raw-notes\/)/,'$1');link.after(audio);}});

if(noteMatch){const body=document.querySelector('#wiki-body .markdown-body')||document.querySelector('#wiki-body');if(body){const nodes=[...body.childNodes];let bubble;for(const node of nodes){if(node.nodeName==='HR'){bubble=null;node.remove();continue;}if(!bubble && node.nodeType===3 && !node.textContent.trim()){node.remove();continue;}if(!bubble){bubble=document.createElement('article');bubble.className='raw-message';bubble.setAttribute('aria-label','Note message');body.append(bubble);}bubble.append(node);}}}
