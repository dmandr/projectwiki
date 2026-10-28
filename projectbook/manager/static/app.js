const $ = selector => document.querySelector(selector);
let books = [], mcpUrl = '', removing = null, lastRender = '', busy = false, cf = {}, editingUsers = null, people = [], gh = {};
const states = {preparing_repository:"Preparing GitHub repository",protecting:'Protecting address',publishing:'Publishing address',updating_access:'Updating access',queued:'Queued',cloning:'Cloning repository',starting:'Starting services',ready:'Ready',saving:'Saving to Git',removing:'Removing',removed:'Removed',error:'Needs attention'};
function el(tag, cls, text) { const node = document.createElement(tag); if(cls)node.className=cls;if(text!==undefined)node.textContent=text;return node; }
async function api(path, data) { const response = await fetch(path, data===undefined ? {} : {method:'POST',headers:{'Content-Type':'application/json','X-ProjectBook-Request':'1'},body:JSON.stringify(data)});const value=await response.json();if(!response.ok)throw Error(value.error||'Request failed');return value; }
function notice(message) { $('#notice').textContent=message;$('#notice').hidden=!message; }
function render() {
  const showRemoved=$('#show-removed').checked;const key=JSON.stringify([books,showRemoved]);if(key===lastRender)return;lastRender=key;
  const root=$('#books');root.replaceChildren();$('#book-count').textContent=books.filter(b=>b.state!=='removed').length;
  const shown=books.filter(b=>showRemoved||b.state!=='removed').reverse();
  if(!shown.length){const empty=el('div','empty');empty.append(el('h3','', 'Your next book starts here.'),el('p','','Give it a name, a web address and a Git repository. Project Book takes care of the installation.'));root.append(empty);}
  for(const b of shown){
    const card=el('article','book');const main=el('div','book-main'),info=el('div'),title=el('div','book-name');title.append(el('h3','',b.name),el('span','badge '+b.state,states[b.state]||b.state));info.append(title,el('div','repo',b.repo));
    const details=el('div','details');const address=el('a','',b.url);address.href=b.url;address.target='_blank';address.rel='noopener';details.append(address);
    if(b.port){const port=el('span','','Origin ');port.append(el('code','','127.0.0.1:'+b.port));details.append(port);}details.append(el('span','','ID '+b.id));info.append(details);
    const actions=el('div','actions');if(b.state==='ready'){const open=el('a','','Open book ↗');open.href=b.url;open.target='_blank';open.rel='noopener';actions.append(open);}
    if(b.cloudflare?.app_id&&b.cloudflare?.dns_id&&['ready','error'].includes(b.state)){const users=el('button','quiet','People');users.onclick=async()=>{try{await loadPeople();editingUsers=b;$('#users-title').textContent=b.name;renderPicker('#edit-people',b.users||[]);$('#users-error').textContent='';$('#users-dialog').showModal();}catch(e){notice(e.message);}};actions.append(users);}
    if(b.state==='error'){const retry=el('button','quiet','Retry');retry.onclick=async()=>{retry.disabled=true;try{await api('/api/books/'+b.id+'/retry',{});await refresh();}catch(e){notice(e.message);retry.disabled=false;}};actions.append(retry);}
    if(['ready','error'].includes(b.state)){const remove=el('button','quiet','Remove');remove.onclick=()=>{removing=b;$('#remove-title').textContent='Remove '+b.name+'?';$('#remove-confirm').value='';$('#remove-error').textContent='';$('#remove-dialog').showModal();};actions.append(remove);}
    main.append(info,actions);card.append(main);
    if(b.error)card.append(el('p','error',b.error));
    if(b.state==='removed')card.append(el('p','hint','Saved to Git · '+(b.saved_revision||'').slice(0,12)+' · Storage retained for recovery'));
    if(b.state==='ready') {const status=el('p','hint',b.indexing?'Search: checking index…':'Semantic search disabled');status.dataset.index=b.id;card.append(status);}
    if(b.cloudflare){card.append(el('p','hint','Cloudflare: '+(b.cloudflare.state||'pending')+' · '+(b.users||[]).length+' people with access'));}
    if(b.port&&b.state!=='removed'&&!b.cloudflare){const route=el('details','route');route.append(el('summary','','Cloudflare setup'),el('p','','Route '+new URL(b.url).hostname+' to http://127.0.0.1:'+b.port+' on the Docker host. Protect that hostname with a Cloudflare Access application before sharing it.'),el('p','','Agents connect through the shared MCP address above. This book does not need a separate OAuth connection.'));card.append(route);}
    root.append(card);
  }
}
async function refresh(){if(busy)return;busy=true;try{const data=await api('/api/books');books=data.books;mcpUrl=data.mcp_url;cf=data.cloudflare||{};gh=await api('/api/github');configureCloudflare();configureGitHub();$('#mcp-url').textContent=mcpUrl;$('#connection').textContent=data.auth_mode==='local'?'Local development':'Cloudflare protected';render();for(const b of books.filter(b=>b.state==='ready'&&b.indexing)){const data=await api('/api/books/'+b.id+'/index');const node=document.querySelector('[data-index="'+b.id+'"]');if(node)node.textContent='Search: '+(data.state||'starting')+(data.phase?' · '+data.phase:'')+(data.processed_files?' · '+data.processed_files+' files':'');}}catch(e){notice(e.message);$('#connection').textContent='Connection unavailable';}finally{busy=false;}}
$('#new-book').onclick=async()=>{try{await loadPeople();renderPicker('#create-people',[]);$('#create-panel').hidden=false;$('#create-form input').focus();}catch(e){notice(e.message);}};
$('#close-create').onclick=()=>{$('#create-panel').hidden=true;};
$('#show-removed').onchange=render;
$('#copy-mcp').onclick=async()=>{try{await navigator.clipboard.writeText(mcpUrl);$('#copy-mcp').textContent='Copied';setTimeout(()=>$('#copy-mcp').textContent='Copy address',1800);}catch{notice('MCP address: '+mcpUrl);}};
$('#create-form').onsubmit=async event=>{event.preventDefault();const form=event.currentTarget,button=form.querySelector('button[type=submit]');button.disabled=true;notice('');try{const data=new FormData(form);await api('/api/books',{name:data.get('name'),url:data.get('url'),repo:data.get('repo'),subdomain:data.get('subdomain'),users:selectedPeople('#create-people'),indexing:form.elements.indexing.checked});form.reset();$('#create-panel').hidden=true;await refresh();}catch(e){notice(e.message);}finally{button.disabled=false;}};
$('#cancel-remove').onclick=()=>$('#remove-dialog').close();
$('#remove-form').onsubmit=async event=>{event.preventDefault();const button=event.currentTarget.querySelector('button[type=submit]');button.disabled=true;try{await api('/api/books/'+removing.id+'/remove',{confirm:$('#remove-confirm').value});$('#remove-dialog').close();await refresh();}catch(e){$('#remove-error').textContent=e.message;}finally{button.disabled=false;}};
function configureCloudflare(){
  const automatic=!!cf.enabled,form=$('#create-form');
  $('#manual-address').hidden=automatic;form.elements.url.required=!automatic;
  $('#automatic-address').hidden=!automatic;form.elements.subdomain.required=automatic;
  $('#create-users-label').hidden=!automatic;
  $('#base-domain').textContent='.'+(cf.base_domain||'dmandr.net');
  $('#cloudflare-status').textContent=automatic?(cf.configured?'Automatic setup · '+cf.base_domain+' · DNS, application and policy are created automatically.':'Cloudflare setup required: install the server API token before creating books.'):'Cloudflare automation is not configured. Domain routing is manual.';
  $('#new-book').disabled=automatic&&!cf.configured;
}
$('#check-address').onclick=async()=>{const subdomain=$('#create-form').elements.subdomain.value,button=$('#check-address');button.disabled=true;$('#address-result').textContent='Checking DNS, Access and tunnel…';try{const r=await api('/api/cloudflare/check',{subdomain});if($('#create-form').elements.subdomain.value===subdomain)$('#address-result').textContent=r.hostname+' is available. Checked again when you create the book.';}catch(e){$('#address-result').textContent=e.message;}finally{button.disabled=false;}};
$('#create-form').elements.subdomain.oninput=()=>{$('#address-result').textContent='';};
$('#cancel-users').onclick=()=>$('#users-dialog').close();
$('#users-form').onsubmit=async event=>{event.preventDefault();const button=event.currentTarget.querySelector('button[type=submit]');button.disabled=true;try{await api('/api/books/'+editingUsers.id+'/users',{users:selectedPeople('#edit-people'),expected_users:editingUsers.users});$('#users-dialog').close();await refresh();}catch(e){$('#users-error').textContent=e.message;}finally{button.disabled=false;}};
function selectedPeople(selector){return [...document.querySelectorAll(selector+' input:checked')].map(input=>input.value);}
async function loadPeople(){const data=await api('/api/people');people=data.people;}
function renderPicker(selector,selected){const root=$(selector);root.replaceChildren();if(!people.length)root.append(el('p','hint','No people yet. Add yourself and your collaborators in People.'));for(const person of people){const label=el('label','person-choice'),input=el('input');input.type='checkbox';input.value=person.email;input.checked=selected.includes(person.email);label.append(input,el('span','',person.name+' · '+person.email));root.append(label);}}
function renderPeople(){const root=$('#people-list');root.replaceChildren();$('#people-count').textContent=people.length+' / 50';for(const person of people){const row=el('div','person-row'),info=el('div');info.append(el('strong','',person.name),el('div','hint',person.email));const remove=el('button','quiet','Remove');remove.onclick=async()=>{remove.disabled=true;try{await api('/api/people/'+person.id+'/remove',{});await loadPeople();renderPeople();}catch(e){$('#people-error').textContent=e.message;remove.disabled=false;}};row.append(info,remove);root.append(row);}}
$('#manage-people').onclick=async()=>{try{await loadPeople();renderPeople();$('#people-error').textContent='';$('#people-dialog').showModal();}catch(e){notice(e.message);}};
$('#close-people').onclick=()=>{$('#people-dialog').close();renderPicker('#create-people',selectedPeople('#create-people'));};
$('#person-form').onsubmit=async event=>{event.preventDefault();const form=event.currentTarget,button=form.querySelector('button[type=submit]');button.disabled=true;$('#people-error').textContent='';try{await api('/api/people',{name:form.elements.name.value,email:form.elements.email.value});form.reset();await loadPeople();renderPeople();}catch(e){$('#people-error').textContent=e.message;}finally{button.disabled=false;}};
function configureGitHub(){
  $('#github-panel').hidden=!gh.enabled;
  $('#github-status').textContent=!gh.configured?'GitHub App setup required':gh.connected?'Connected as '+gh.login+' · short-lived OAuth tokens':'Sign in as '+gh.owner+' to check access and create repositories.';
  $('#connect-github').textContent=gh.connected?'Reconnect GitHub':'Connect GitHub';
  $('#connect-github').disabled=!gh.configured;
  $('#check-repository').hidden=!gh.enabled;
  $('#repository-help').textContent=gh.enabled?'Use '+gh.owner+'/book-name. Existing repositories require write access. If the repository is absent, a private repository is created in your account.':'The repository must already exist. Private repositories use the server’s Git credentials.';
  $('#new-book').disabled=(cf.enabled&&!cf.configured)||(gh.enabled&&!gh.connected);
}
$('#connect-github').onclick=async()=>{try{const result=await api('/api/github/connect',{});location.assign(result.url);}catch(e){notice(e.message);}};
$('#check-repository').onclick=async()=>{const button=$('#check-repository'),repo=$('#create-form').elements.repo.value;button.disabled=true;$('#repository-result').textContent='Checking your GitHub identity and write access…';try{const result=await api('/api/github/check',{repo});if($('#create-form').elements.repo.value===repo)$('#repository-result').textContent=result.message;}catch(e){$('#repository-result').textContent=e.message;}finally{button.disabled=false;}};
$('#create-form').elements.repo.oninput=()=>{$('#repository-result').textContent='';};
const githubResult=new URLSearchParams(location.search).get('github');
if(githubResult){notice(githubResult==='connected'?'GitHub connected. You can now create a book.':'GitHub connection failed or was cancelled. Check the account and App settings, then try Connect GitHub again.');history.replaceState(null,'','/');}
refresh();setInterval(refresh,4000);
