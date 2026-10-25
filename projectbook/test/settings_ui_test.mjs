import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const template = readFileSync(new URL('../../lib/gollum/templates/projectbook_settings.mustache', import.meta.url), 'utf8');
const script = template.match(/<script>([\s\S]*?)<\/script>/)[1];
const flush = () => new Promise(resolve => setImmediate(resolve));
function page() {
  const nodes = new Map();
  const element = id => {
    if (!nodes.has(id)) nodes.set(id, { textContent: '', disabled: true, events: {}, addEventListener(name, fn) { this.events[name] = fn; } });
    return nodes.get(id);
  };
  const settings = {enabled:true,auto_index:true,include_pdf:true,poll_seconds:60,batch_size:16,default_mode:'hybrid',result_limit:8};
  element('pb-settings-form').elements = Object.fromEntries(Object.keys(settings).map(key => [key, {value:'',checked:false}]));
  let offline = true, poll;
  vm.runInNewContext(script, {
    baseUrl:'', document:{hidden:false,getElementById:element}, window:{addEventListener() {},confirm:()=>true},
    setInterval(fn) { poll=fn; return 1; }, clearInterval() {},
    fetch: async () => {
      if (offline) throw new TypeError('Load failed');
      return {ok:true,json:async()=>({available:true,editable:true,settings:{...settings},version:'v1',status:{state:'ready',model_loaded:true,settings}})};
    }
  });
  return {element, online:()=>{offline=false;}, offline:()=>{offline=true;}, poll:()=>poll()};
}

test('initial network failure recovers without requiring a page reload', async () => {
  const p=page(); await flush();
  assert.match(p.element('pb-settings-connection').textContent,/Retrying automatically/);
  assert.equal(p.element('pb-settings-fields').disabled,true);
  p.online(); p.poll(); await flush();
  assert.equal(p.element('pb-settings-connection').textContent,'');
  assert.equal(p.element('pb-settings-fields').disabled,false);
  assert.equal(p.element('pb-settings-form').elements.poll_seconds.value,60);
  assert.equal(p.element('pb-settings-save').disabled,true);
});

test('poll recovery clears only connection errors and preserves a settings draft', async () => {
  const p=page(); await flush(); p.online(); p.poll(); await flush();
  const form=p.element('pb-settings-form');
  form.elements.poll_seconds.value='61'; form.events.input();
  p.offline(); p.poll(); await flush();
  assert.match(p.element('pb-settings-connection').textContent,/Retrying automatically/);
  p.online(); p.poll(); await flush();
  assert.equal(p.element('pb-settings-connection').textContent,'');
  assert.equal(form.elements.poll_seconds.value,'61');
  assert.equal(p.element('pb-settings-message').textContent,'Unsaved settings.');
  assert.equal(p.element('pb-settings-save').disabled,false);
  p.element('pb-settings-message').textContent='Settings version conflict';
  p.poll(); await flush();
  assert.equal(p.element('pb-settings-message').textContent,'Settings version conflict');
});
