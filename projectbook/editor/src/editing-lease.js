// Fence interaction after a suspended tab's lease expires, before it can edit.
export function editingLease(root, base = '') {
  const session = crypto.randomUUID();
  let until = 0, pending = false, closed = false;
  const overlay = document.createElement('div');
  overlay.className = 'pb-update-wait';
  overlay.textContent = 'Connecting editor…';
  document.body.append(overlay);
  async function heartbeat() {
    if (pending || closed) return;
    pending = true;
    try {
      const response = await fetch(base + '/gollum/projectbook/editing', {method:'POST',headers:{'Content-Type':'application/json','X-ProjectWiki-Request':'1'},body:JSON.stringify({action:'heartbeat',session})});
      if (!response.ok) throw Error('Book is updating or unavailable. Your draft is kept. Reconnecting…');
      until = Date.now() + 120000; overlay.hidden = true;
    } catch (error) { until = 0; overlay.textContent = error.message; overlay.hidden = false; }
    finally { pending = false; }
  }
  function fence(event) {
    if (Date.now() < until) return;
    event.preventDefault(); event.stopImmediatePropagation();
    overlay.hidden = false; void heartbeat();
  }
  for (const name of ['beforeinput','keydown','paste','drop','pointerdown','click']) root.addEventListener(name, fence, true);
  const timer = setInterval(heartbeat, 20000);
  const resume = () => { if (!document.hidden) { if(Date.now() >= until) overlay.hidden = false; void heartbeat(); } };
  document.addEventListener('visibilitychange',resume);
  window.addEventListener('focus',resume);
  window.addEventListener('pageshow',resume);
  window.addEventListener('pagehide',() => {
    until = 0;
    void fetch(base + '/gollum/projectbook/editing',{method:'POST',keepalive:true,headers:{'Content-Type':'application/json','X-ProjectWiki-Request':'1'},body:JSON.stringify({action:'close',session})});
  });
  void heartbeat();
}
