import React, {useEffect,useRef,useState} from 'react';
import {createRoot} from 'react-dom/client';
import {draftStore} from './drafts.js';
import './raw-notes.css';
const base=window.baseUrl||'';
const endpoint=base+'/gollum/projectbook/raw-notes';
async function api(action,body){
 const response=await fetch(endpoint+(action?'/'+action:''),body?{method:'POST',headers:{'Content-Type':'application/json','X-ProjectWiki-Request':'1'},body:JSON.stringify(body)}:{cache:'no-store'});
 const data=await response.json();if(!response.ok)throw Error(data.error||'Request failed');return data;
}
const makeDraft=()=>({id:crypto.randomUUID(),title:'',text:'',files:[]});
const key=base+':raw-note';
const bytes64=bytes=>{let result='';for(let i=0;i<bytes.length;i++)result+=String.fromCharCode(bytes[i]);return btoa(result);};
function Media({item}){
 const [url,setURL]=useState('');useEffect(()=>{const value=URL.createObjectURL(item.blob);setURL(value);return()=>URL.revokeObjectURL(value);},[item.blob]);
 return item.mime_type.startsWith('image/')?<img src={url} alt={item.name}/>:<audio src={url} controls preload="metadata"/>;
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
function Capture(){
 const [draft,setDraft]=useState(makeDraft),[ready,setReady]=useState(false),[notice,setNotice]=useState(''),[busy,setBusy]=useState(false),[recording,setRecording]=useState(false),[original,setOriginal]=useState(false),[local,setLocal]=useState('');
 const recorder=useRef(),stream=useRef(),saveQueue=useRef(Promise.resolve()),saved=useRef(false),latest=useRef(draft);latest.current=draft;
 useEffect(()=>{draftStore('get',key).then(d=>{if(d){setDraft(d);setNotice('Restored your local draft.');}}).catch(()=>setLocal('Browser draft storage is unavailable. Keep this tab open.')).finally(()=>setReady(true));return()=>{if(recorder.current?.state==='recording')recorder.current.stop();stream.current?.getTracks().forEach(t=>t.stop());};},[]);
 useEffect(()=>{if(!ready||saved.current)return;saveQueue.current=saveQueue.current.catch(()=>{}).then(()=>draftStore('put',key,draft)).then(()=>setLocal('Draft saved on this device · not yet in the book')).catch(()=>setLocal('Draft could not be stored. Keep this tab open.'));},[draft,ready]);
 useEffect(()=>{const warn=e=>{if(!saved.current&&(latest.current.text||latest.current.files.length||recorder.current?.state==='recording')){e.preventDefault();e.returnValue='';}};window.addEventListener('beforeunload',warn);return()=>window.removeEventListener('beforeunload',warn);},[]);
 function append(item){if(item.blob.size>20*1024*1024){setNotice('File exceeds 20 MiB. Choose a smaller file.');return;}setDraft(d=>({...d,files:[...d.files,{...item,upload_id:crypto.randomUUID()}]}));}
 async function addFiles(event){const files=[...event.target.files];event.target.value='';setBusy(true);setNotice('Preparing attachments…');try{for(const file of files){if(!/^(image|audio)\//.test(file.type)&&!(/\.heic$/i.test(file.name)))throw Error('Only photos and audio are supported.');append(await photo(file,original));}setNotice('');}catch(e){setNotice(e.message);}finally{setBusy(false);}}
 async function record(){
 if(recording){recorder.current.stop();return;}
 try{
  if(!navigator.mediaDevices?.getUserMedia||!window.MediaRecorder)throw Error('Voice recording requires HTTPS (or localhost) and a supported browser. You can also attach an audio file.');
  stream.current=await navigator.mediaDevices.getUserMedia({audio:true});
  const mime=['audio/mp4','audio/webm;codecs=opus','audio/webm','audio/ogg;codecs=opus'].find(t=>MediaRecorder.isTypeSupported(t));
  const rec=new MediaRecorder(stream.current,mime?{mimeType:mime}:undefined);recorder.current=rec;let parts=[],size=0;
  rec.ondataavailable=e=>{if(e.data.size){parts.push(e.data);size+=e.data.size;if(size>=18*1024*1024&&rec.state==='recording'){rec.stop();setNotice('Recording stopped at the size limit.');}}};
  rec.onerror=()=>{setNotice('Recording was interrupted. Check the recorded clip before saving.');stream.current?.getTracks().forEach(t=>t.stop());setRecording(false);};
  rec.onstop=()=>{stream.current?.getTracks().forEach(t=>t.stop());setRecording(false);const type=rec.mimeType.split(';')[0],blob=new Blob(parts,{type});if(blob.size)append({blob,name:'Voice recording',mime_type:type});};
  rec.start(1000);setRecording(true);setNotice('Recording… keep this page open until you stop.');
 }catch(e){stream.current?.getTracks().forEach(t=>t.stop());setNotice(e.message);}
 }
 async function save(){setBusy(true);setNotice('Uploading…');try{
  if(draft.files.length>20||draft.files.reduce((n,f)=>n+f.blob.size,0)>50*1024*1024)throw Error('Use at most 20 files and 50 MiB per note.');
  const attachments=[];
  for(let n=0;n<draft.files.length;n++){
   const f=draft.files[n],bytes=new Uint8Array(await f.blob.arrayBuffer());
   const sha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
   for(let offset=0;offset<bytes.length;offset+=262144){setNotice(`Uploading ${n+1}/${draft.files.length} · ${Math.round(offset/bytes.length*100)}%`);let error;for(let attempt=0;attempt<3;attempt++){try{await api('upload',{upload_id:f.upload_id,offset,data:bytes64(bytes.slice(offset,offset+262144))});error=null;break;}catch(e){error=e;}}if(error)throw error;}
   attachments.push({upload_id:f.upload_id,name:f.name,mime_type:f.mime_type,sha256});
  }
  setNotice('Saving note and attachments to the book…');const result=await api('create',{id:draft.id,title:draft.title,text:draft.text,attachments});saved.current=true;await saveQueue.current;await draftStore('delete',key);location.href=result.url;
 }catch(e){setNotice(e.message+' Your draft is kept; you can retry.');}finally{setBusy(false);}}
 if(!ready)return <p>Restoring draft…</p>;
 return <section className="raw-capture"><div className="raw-heading"><h1>New raw note</h1><a href={base+'/gollum/raw-notes'}>Raw Notes</a></div><p>Capture now. Organize later.</p><fieldset disabled={busy}><label>Title <span>(optional)</span><input value={draft.title} maxLength={200} placeholder="Date and time if left blank" onChange={e=>setDraft({...draft,title:e.target.value})}/></label><label>Text<textarea rows={5} value={draft.text} placeholder="Comments, measurements, observations…" onChange={e=>setDraft({...draft,text:e.target.value})}/></label><div className="raw-tools"><button type="button" className="btn" onClick={record}>{recording?'■ Stop recording':'● Record voice'}</button><label className="btn">Camera<input type="file" accept="image/*" capture="environment" onChange={addFiles}/></label><label className="btn">Add photos / audio<input type="file" accept="image/*,audio/*" multiple onChange={addFiles}/></label></div><label className="raw-original"><input type="checkbox" checked={original} onChange={e=>setOriginal(e.target.checked)}/> Keep original photos (otherwise resize to 2048 px)</label><div className="raw-media">{draft.files.map(f=><figure key={f.upload_id}><Media item={f}/><figcaption>{f.name} · {(f.blob.size/1024).toFixed(0)} KiB {f.warning&&<span>{f.warning}</span>}</figcaption><button type="button" className="btn" onClick={()=>setDraft(d=>({...d,files:d.files.filter(a=>a.upload_id!==f.upload_id)}))}>Remove</button></figure>)}</div><button type="button" className="btn btn-primary" disabled={recording||(!draft.text.trim()&&!draft.files.length)} onClick={save}>Save to Unsorted</button></fieldset><p className="raw-local">{local}</p><p role="status">{notice}</p></section>;
}
function Inbox(){
 const [items,setItems]=useState([]),[filter,setFilter]=useState('unsorted'),[error,setError]=useState(''),[editable,setEditable]=useState(false);
 async function load(){try{const data=await api();setItems(data.items);setEditable(data.editable);}catch(e){setError(e.message);}}
 useEffect(()=>{load();},[]);
 async function status(item){try{await api('status',{id:item.id,expected_version:item.version,status:item.status==='processed'?'unsorted':'processed',results:item.results});await load();}catch(e){setError(e.message);}}
 return <section className="raw-inbox"><div className="raw-heading"><h1>Raw Notes</h1>{editable&&<a className="btn btn-primary" href={base+'/gollum/raw-notes/new'}>＋ New raw note</a>}</div><div className="raw-tools" role="group" aria-label="Note status">{['unsorted','processed','all'].map(value=><button className="btn" aria-pressed={value===filter} key={value} onClick={()=>setFilter(value)}>{value[0].toUpperCase()+value.slice(1)}</button>)}</div><p role="status">{error}</p>{items.filter(n=>filter==='all'||n.status===filter).map(note=><article key={note.id}><h2><a href={note.url}>{note.title}</a></h2><p>{new Date(note.created_at).toLocaleString()} · {note.attachments.length} attachments · {note.source}</p>{note.attachments.find(f=>f.mime_type.startsWith('image/'))&&<img loading="lazy" alt="Photo preview" src={base+'/'+note.attachments.find(f=>f.mime_type.startsWith('image/')).path.split('/').map(encodeURIComponent).join('/')}/>} {editable&&<button className="btn" onClick={()=>status(note)}>{note.status==='processed'?'Return to Unsorted':'Mark processed'}</button>}</article>)}{!items.some(n=>filter==='all'||n.status===filter)&&<p>No {filter==='all'?'':filter} notes yet.</p>}</section>;
}
const mount=document.getElementById('projectbook-raw-notes');if(mount)createRoot(mount).render(location.pathname.endsWith('/new')?<Capture/>:<Inbox/>);
// Keep ordinary Markdown download links; add a native player beside audio links.
if(location.pathname.includes('/raw-notes/'))document.querySelectorAll('.markdown-body a').forEach(link=>{const url=new URL(link.href,location.href);if(url.origin===location.origin&&/\/media\/voice-\d+\.(m4a|mp3|webm|ogg|wav)$/.test(url.pathname)){const audio=document.createElement('audio');audio.controls=true;audio.preload='metadata';audio.src=base+'/'+url.pathname.replace(/^.*?(raw-notes\/)/,'$1');link.after(audio);}});
