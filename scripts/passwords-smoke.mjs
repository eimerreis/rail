#!/usr/bin/env node
// Uses a disposable browser profile and an in-memory vault. Never opens a real
// 1Password account. Credential values are asserted in-page, never printed.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { mkdir, mkdtemp, readFile, writeFile, rename, copyFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
await mkdir(resolve(root,'.runtime-test'),{recursive:true});
const profile=await mkdtemp(resolve(root,'.runtime-test/passwords-'));
const formScript=await readFile(resolve(root,'src/CredentialForm.js'),'utf8');
const fixture=createServer((req,res)=>{
  const signup=req.url.startsWith('/signup');
  res.setHeader('Content-Type','text/html');
  res.end(`<!doctype html><title>Rail password fixture</title><style>body{font:16px system-ui;margin:70px;background:#faf8f2;color:#292d29}form{width:340px}input,button{display:block;margin:16px 0;padding:12px;width:300px}h1{font-size:30px}</style><h1>${signup?'Create an account':'Sign in'}</h1><form id="login"><input name="username" autocomplete="username" placeholder="Email"><input type="password" autocomplete="${signup?'new-password':'current-password'}">${signup?'<input type="password" name="confirmation" autocomplete="new-password">':''}<input type="hidden" name="hidden" value="untouched"><button>Continue</button></form><script>window.events=0;window.submits=0;document.addEventListener('input',()=>events++);document.addEventListener('change',()=>events++);document.querySelector('form').onsubmit=e=>{e.preventDefault();submits++}</script>`);
});
fixture.listen(0,'127.0.0.1'); await once(fixture,'listening');
const origin=`http://localhost:${fixture.address().port}`;
const probe=createServer(); probe.listen(0,'127.0.0.1'); await once(probe,'listening'); const port=probe.address().port; await new Promise(r=>probe.close(r));
const app=resolve(root,process.env.RAIL_TEST_APP || 'build/Release/Rail.app');
const log=resolve(profile,'app.log');
const child=spawn('/usr/bin/open',['-n','-W','--stdout',log,'--stderr',log,app,'--args',`--data-dir=${profile}`,'--automation',`--debug-port=${port}`,`--password-fixture-origin=${origin}`,'-ApplePersistenceIgnoreState','YES'],{stdio:'ignore'});
const exited=once(child,'exit'); let sequence=0,quitting=false;
async function until(label,task,timeout=15000){ const end=Date.now()+timeout; while(Date.now()<end){ if(child.exitCode!==null&&!quitting)throw new Error(`Rail exited: ${profile}`); try{const r=await task();if(r)return r;}catch{} await new Promise(r=>setTimeout(r,80)); } throw new Error(`Timed out: ${label}. ${profile}`); }
const state=async()=>JSON.parse(await readFile(resolve(profile,'automation-state.json'),'utf8'));
async function command(action,args={}){ const id=String(++sequence); const tmp=resolve(profile,'command.tmp'); await writeFile(tmp,JSON.stringify({id,action,...args}));await rename(tmp,resolve(profile,'automation-command.json')); if(action!=='quit')return until(action,async()=>{const s=await state();return s.command===id&&s}); }
async function targets(){return (await fetch(`http://127.0.0.1:${port}/json/list`)).json();}
async function cdp(page,method,params={}){ const ws=new WebSocket(page.webSocketDebuggerUrl);await once(ws,'open');try{return await new Promise((res,rej)=>{const timer=setTimeout(()=>rej(new Error('CDP timeout')),5000);ws.addEventListener('message',event=>{const m=JSON.parse(event.data);if(m.id!==1)return;clearTimeout(timer);m.error?rej(new Error(m.error.message)):res(m.result)});ws.send(JSON.stringify({id:1,method,params}));});}finally{ws.close();} }
async function evaluate(page,expression){const r=await cdp(page,'Runtime.evaluate',{expression,returnByValue:true});if(r.exceptionDetails)throw new Error('Page assertion threw');return r.result.value;}
async function paletteReady(){return until('palette ready',async()=>{const s=await state();return s.passwords?.visible&&!s.passwords.busy&&s.passwords;});}
async function settled(){return until('palette settled',async()=>{const s=await state();return s.passwords&&!s.passwords.busy&&s.passwords;});}
async function button(title,args={}){await command('passwordControl',{button:title,...args});return settled();}
async function closePalette(){await command('passwordControl',{button:'Escape'});}
async function capture(name){await command('capture');const id=(await state()).passwords.windowNumber;const result=spawnSync('/usr/sbin/screencapture',['-x','-l',String(id),resolve(profile,`${name}.png`)],{encoding:'utf8'});if(result.status!==0){await copyFile(resolve(profile,'password-palette.png'),resolve(profile,`${name}.png`));console.log(`Window capture unavailable for ${name}; native snapshot used: ${result.stderr.trim()}`);}}
async function openPage(path){await closePalette();await command('navigate',{url:origin+path});return until('page',async()=>{const p=(await targets()).find(t=>t.url===origin+path);return p&&await evaluate(p,'document.readyState === "complete"')&&p;});}

try{
 await until('startup',state); await command('newTab',{url:origin+'/login'});
 let page=await until('fixture',async()=>(await targets()).find(t=>t.url===origin+'/login'&&t.title==='Rail password fixture'));
 await command('passwords'); await paletteReady(); await capture('connect');
 await button('Connect 1Password',{account:'Rail Test'}); assert.equal((await paletteReady()).total,83); assert.equal((await paletteReady()).count,40); await capture('fill');
 await button('→'); assert.equal((await paletteReady()).offset,40);
 await button('→'); assert.equal((await paletteReady()).offset,80); assert.equal((await paletteReady()).count,3);
 await button('←'); assert.equal((await paletteReady()).offset,40);
 await command('passwordControl',{query:'localhost'}); assert.equal((await paletteReady()).count,1,'search should include saved websites');
 await command('passwordControl',{query:'reference 079'}); assert.equal((await paletteReady()).count,1,'search must reach beyond first results');
 await command('passwordControl',{button:'Refresh'}); assert.equal((await state()).passwords.searchEnabled,true,'typing stays available during refresh');
 await command('passwordControl',{query:'elsewhere'}); await command('passwordControl',{query:'Passport'});
 assert.equal((await paletteReady()).query,'Passport'); assert.equal((await paletteReady()).count,1); assert.equal((await paletteReady()).action,'Open in 1Password');
 await command('shortcut',{key:'\r',keyCode:36,modifiers:[],window:'passwords'});
 await until('private-link setup',async()=>(await state()).passwords.linkSetup);
 await button('Open item',{privateLink:'https://start.1password.com/open/i?a=fixture-account&h=my.1password.com&v=fixture&i=note'});
 await until('item opened',async()=>!(await state()).passwords.visible);
 const itemLink=new URL((await state()).passwords.openedURL); assert.equal(itemLink.protocol,'onepassword:'); assert.equal(itemLink.searchParams.get('i'),'note'); assert.equal(itemLink.searchParams.get('a'),'fixture-account');
 assert.equal(await evaluate(page,'document.querySelector("[type=password]").value==="" && submits===0'),true,'non-login item must not fill');
 await command('passwords'); await paletteReady();
 await command('passwordControl',{query:''}); await paletteReady();
 await command('shortcut',{key:'\r',keyCode:36,modifiers:[],window:'passwords'}); await until('Return fills and dismisses',async()=>!(await state()).passwords.visible);
 assert.equal(await evaluate(page,`document.querySelector('[name=username]').value==='demo@example.test' && document.querySelector('[type=password]').value==='Rail-disposable-test-123!' && events===4 && submits===0 && document.querySelector('[name=hidden]').value==='untouched'`),true);
 page=await openPage('/login/cross-site'); await command('passwords'); await paletteReady();
 await command('passwordControl',{query:'elsewhere'}); await paletteReady(); await button('Fill selected login'); assert.equal((await paletteReady()).confirming,true); await capture('cross-site');
 await button('Cancel'); assert.equal((await paletteReady()).confirming,false); assert.equal(await evaluate(page,'document.querySelector("[type=password]").value===""'),true);
 await button('Fill selected login'); await command('passwordControl',{button:'Fill this website'}); await until('cross-site fill',async()=>!(await state()).passwords.visible);
 assert.equal(await evaluate(page,`document.querySelector('[name=username]').value==='elsewhere@example.test' && document.querySelector('[type=password]').value==='Rail-other-fixture-123!' && submits===0`),true);
 page=await openPage('/login');
 // Same-URL reload while credentials are still being fetched must invalidate the document.
 await closePalette(); await cdp(page,'Page.reload'); await until('reload',()=>evaluate(page,'document.readyState==="complete" && document.querySelector("[type=password]").value===""'));
 await command('passwords'); await paletteReady(); assert.equal((await command('passwordControl',{button:'Fill selected login'})).passwords.busy,true); await cdp(page,'Page.reload'); await paletteReady();
 assert.equal(await evaluate(page,'document.querySelector("[type=password]").value===""'),true);
 page=await openPage('/signup'); await command('passwords'); await paletteReady(); await button('New login'); await capture('new-login');
 await button('New login',{title:'Created fixture',username:'new@example.test'}); // Active view must not erase these edits.
 await command('shortcut',{key:'\r',keyCode:36,modifiers:['cmd'],window:'passwords'}); await until('Cmd Return saves and dismisses',async()=>{const p=(await state()).passwords;return p.saved&&!p.visible;});
 assert.equal((await state()).passwords.saved,true); assert.equal((await state()).passwords.visible,false);
 assert.equal(await evaluate(page,`(()=>{const p=[...document.querySelectorAll('[type=password]')];return p.length===2&&p[0].value.length===24&&p[0].value===p[1].value&&document.querySelector('[name=username]').value==='new@example.test'&&events===6&&submits===0})()`),true);
 // Reopening shows the created item; password was generated by the actual SDK.
 await closePalette(); await command('passwords'); assert.equal((await paletteReady()).total,84);
 await button('New login'); await button('Save only',{title:'Saved only fixture',username:'save@example.test'}); assert.equal((await paletteReady()).saved,true); assert.doesNotMatch((await state()).status,/and filled/); await capture('saved');
 await closePalette(); await command('passwords'); assert.equal((await paletteReady()).total,85);
 await button('New login'); await button('Save only',{title:'Uncertain fixture'}); assert.equal((await paletteReady()).uncertain,true);
 await button('Generate again'); assert.equal((await paletteReady()).uncertain,true); assert.match((await paletteReady()).message,/confirm the save/); assert.doesNotMatch((await state()).status,/and filled/); await capture('uncertain');
 await closePalette(); await command('passwords'); assert.equal((await paletteReady()).total,86);
 // Form policy runs in the real Chromium DOM, including event semantics.
 await closePalette();
 const checks=[
  ['ambiguous',`document.body.innerHTML='<form><input type=password></form><form><input type=password></form>'`, 'ambiguous',false],
  ['cross-origin action',`document.body.innerHTML='<form action="https://other.example"><input type=password></form>'`,'unsafe_form',false],
  ['no hidden fill',`document.body.innerHTML='<form><input type=password hidden></form>'`,'no_fields',false],
  ['username first',`document.body.innerHTML='<input name=username autocomplete=username>'`,'username_filled',false],
  ['change password',`document.body.innerHTML='<form><input type=password autocomplete=current-password><input type=password autocomplete=new-password></form>'`,'ambiguous',true],
  ['iframe isolation',`document.body.innerHTML='<iframe srcdoc="<input type=password>"></iframe>'`,'no_fields',false],
 ];
 for(const [name,setup,want,creating] of checks){await evaluate(page,setup);assert.equal(await evaluate(page,`${formScript}('fixture','test-only',${creating})`),want,name);}
 // Check all themes in the same bounded UI inspection round.
 page=await openPage('/signup/themes'); await command('passwords'); await paletteReady(); await button('New login');
 for(const theme of ['nightline','daylight']){await command('theme',{theme});await capture(`new-${theme}`);}
 await closePalette(); await command('home'); await command('passwords'); assert.equal((await paletteReady()).canFill,false); assert.equal((await paletteReady()).total,86);
 await command('passwordControl',{query:'Passport'}); assert.equal((await paletteReady()).count,1); assert.equal((await paletteReady()).action,'Open in 1Password');
 await button('Disconnect'); assert.equal((await paletteReady()).count,0,'disconnect clears search metadata');
 quitting=true;await command('quit'); const [code]=await exited;assert.equal(code,0);
 console.log(`Password smoke passed: account-wide search, pagination, latest query, non-login opening, cross-site confirmation, fill, generation, save & fill, save only, uncertain writes, navigation invalidation, form isolation. Artifacts: ${profile}`);
}finally{
 spawnSync('/usr/bin/pkill',['-f','--',`--data-dir=${profile}`]);if(child.exitCode===null)await exited; await new Promise(r=>fixture.close(r));
}
