// Shared shell and pages for the live checks mockups. Each variant sets window.LIVE before loading this.
// All project, pull request and run data here is synthetic.
const EXTRA = {
  folder:'<path d="M3 7a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/>',
  bookmark:'<path d="M6 4h12v17l-6-4.5L6 21Z"/>',
  download:'<path d="M12 4v11m-4.5-4.5L12 15l4.5-4.5M5 20h14"/>',
  arrowr:'<path d="M5 12h14m-5-5 5 5-5 5"/>'
};
document.body.insertAdjacentHTML('afterbegin','<svg width="0" height="0" style="position:absolute" aria-hidden="true">'+Object.entries(EXTRA).map(([k,v])=>`<symbol id="${k}" viewBox="0 0 24 24">${v}</symbol>`).join('')+'</svg>');
const ic = n => `<svg class="i"><use href="#${n}"/></svg>`;
const ck = s => s==='run' ? '<span class="ck run"></span>' : `<span class="ck ${s}">${ic({ok:'check',fail:'x',warn:'chat'}[s])}</span>`;
const ado = `<span class="fav ado">${ic('ado')}</span>`, gh = `<span class="fav gh">${ic('github')}</span>`;
window.UI = {ic, ck, ado, gh};
const L = Object.assign({rail:'',sideAfterNav:'',barExtra:'',overlay:{},statusLeft:'Work session',activityBadge:1,projectsBadge:2,listRunning:true}, window.LIVE);
const view = {'#activity':'activity','#projects':'projects'}[location.hash] || 'web';
document.body.dataset.view = view;
const URLS = {web:`${ic('laptop')}<span>localhost:3000/invoices</span>`,activity:`${ic('pulse')}<span>Work / Activity</span>`,projects:`${ic('folder')}<span>Work / Projects</span>`};
const fresh = t => `<span class="fresh num">Updated ${t}<button class="ib" aria-label="Check now">${ic('reload')}</button></span>`;

document.body.insertAdjacentHTML('beforeend',`<div class="win">
<nav class="rail" aria-label="Spaces">
  <img src="../icon/rail-r-variants/rail-r-02-rounded.png" alt="Rail">
  <button class="sp on" aria-label="Work Space">${ic('work')}${L.rail}</button>
  <button class="sp" aria-label="Personal Space">${ic('home')}</button>
  <button class="sp" aria-label="Reading">${ic('bookmark')}</button>
  <div class="end"><button class="sp" aria-label="New Space">${ic('plus')}</button><button class="sp" aria-label="Settings">${ic('sliders')}</button></div>
</nav>
<aside class="side">
  <div class="traffic"><span></span><span></span><span></span></div>
  <div class="word">Rail<button class="ib" aria-label="Space options">${ic('dots')}</button></div>
  <div class="spname">Work ${ic('chevron')}</div>
  <div class="nav">
    <div class="${view==='projects'?'on':''}">${ic('folder')}<span class="t">Projects</span><span class="nb">${L.projectsBadge}</span></div>
    <div class="${view==='activity'?'on':''}">${ic('pulse')}<span class="t">Activity</span><span class="nb">${L.activityBadge}</span></div>
  </div>
  ${L.sideAfterNav}
  <div class="sec">Pinned</div>
  <div class="pins"><div class="pin">${ado}DevOps</div><div class="pin">${gh}GitHub</div></div>
  <div class="sec">Tabs</div>
  <div class="tabs">
    <div class="tab ${view==='web'?'on':''}"><span class="fav">${ic('laptop')}</span><span class="t">localhost:3000</span><span class="mk">W</span></div>
    <div class="tab">${ado}<span class="t">PR 1187 · Handle transferred seats</span><span class="mk">W</span></div>
    <div class="tab"><span class="fav ai">${ic('insights')}</span><span class="t">Failures · billing-prod</span><span class="mk i">I</span></div>
    <div class="tab asleep">${ado}<span class="t">Sprint 41 board</span><svg class="i moon"><use href="#moon"/></svg></div>
  </div>
  <div class="foot">${ic('moon')}1 tab asleep</div>
</aside>
<div class="main">
  <div class="bar">
    <button class="ib" aria-label="Back">${ic('back')}</button><button class="ib dim" aria-label="Forward">${ic('fwd')}</button><button class="ib" aria-label="Reload">${ic('reload')}</button>
    <div class="url">${URLS[view]}</div>
    ${(L.barExtra[view]||'')}
    <button class="ib" aria-label="Downloads">${ic('download')}</button>
    <div class="sess">Work ${ic('chevron')}</div>
  </div>
  <div class="page">
    <section class="view web">
      <header><b>Contoso Portal</b><span>Overview</span><span class="on">Invoices</span><span>Licenses</span><span>Team</span></header>
      <main><h1>Invoices</h1><p>Download or forward invoices for your account.</p>
        <table><tr><th>Invoice</th><th>Issued</th><th>Amount</th><th>Status</th><th></th></tr>
        <tr><td>INV-20418</td><td>1 Nov 2026</td><td>€ 1,240.00</td><td><span class="tag d">Due</span></td><td><a>Download PDF</a></td></tr>
        <tr><td>INV-20377</td><td>1 Oct 2026</td><td>€ 1,240.00</td><td><span class="tag">Paid</span></td><td><a>Download PDF</a></td></tr>
        <tr><td>INV-20311</td><td>1 Sep 2026</td><td>€ 1,180.00</td><td><span class="tag">Paid</span></td><td><a>Download PDF</a></td></tr>
        <tr><td>INV-20264</td><td>1 Aug 2026</td><td>€ 1,180.00</td><td><span class="tag">Paid</span></td><td><a>Download PDF</a></td></tr>
        <tr><td>INV-20198</td><td>1 Jul 2026</td><td>€ 1,180.00</td><td><span class="tag">Paid</span></td><td><a>Download PDF</a></td></tr>
        <tr><td>INV-20127</td><td>1 Jun 2026</td><td>€ 960.00</td><td><span class="tag">Paid</span></td><td><a>Download PDF</a></td></tr>
        </table></main>
    </section>

    <section class="view activity">
      <div class="list">
        <div class="lh"><h1>Activity</h1><p>1 needs you · ${fresh('just now')}</p></div>
        <div class="grp">Needs you  1</div>
        <div class="pr flash">${ck('fail')}<b>Handle transferred seats in SeatSync</b><span class="age">now</span><small>License Service · !1187 · integration tests failed</small></div>
        <div class="grp">Waiting on others  3</div>
        <div class="pr">${ck('run')}<b>Add invoice download to account page</b><span class="age">1 h</span><small>Customer Portal · !611 · e2e running · 4 m</small></div>
        <div class="pr">${ck('run')}<b>Add jitter to delivery backoff</b><span class="age">3 h</span><small>Webhook Relay · #214 · test running · 1 m</small></div>
        <div class="pr">${ck('ok')}<b>Retry invoice export on ledger timeout</b><span class="age">5 h</span><small>Billing API · !482 · 1 of 2 approved</small></div>
        <div class="grp">Ready to merge  1</div>
        <div class="pr flash-ok">${ck('ok')}<b>Bump Next.js to 15.5</b><span class="age">3 m</span><small>Status Page · #88 · checks passed, approved</small></div>
      </div>
      <div class="det">
        <div class="dh">${ado}<div><h2>Handle transferred seats in SeatSync</h2><p>License Service · !1187 · <span class="mono">seat-transfer → release/2.14</span> · opened 2 days ago</p></div><button class="btn line">Open in Azure DevOps <span class="mk">W</span></button></div>
        <div class="pills"><span class="pill crit">${ic('x')}1 check failed</span><span class="pill warn">${ic('chat')}2 threads to resolve</span><span class="pill info">${ic('approve')}1 of 2 approvals</span></div>
        <div class="st">Checks <span class="num">run #20261104.4 · finished just now</span></div>
        <div class="box">
          <div class="step">${ck('ok')}<span class="t">Build</span><span class="d">3 m 12 s</span></div>
          <div class="step">${ck('ok')}<span class="t">Unit tests</span><span class="d">1 m 40 s</span></div>
          <div class="step bad">${ck('fail')}<span class="t">Integration tests</span><span class="d">failed after 7 m 48 s</span></div>
          <div class="step">${ck('ok')}<span class="t">Code coverage</span><span class="d">22 s</span></div>
        </div>
        <div class="st">Policies</div>
        <div class="box">
          <div class="step">${ck('warn')}<span class="t">Comments resolved</span><span class="d">2 open threads</span></div>
          <div class="step"><span class="av">JL</span><span class="t">J. Lang</span><span class="d">approved</span></div>
          <div class="step"><span class="av b">RS</span><span class="t">R. Sommer</span><span class="d">not reviewed yet</span></div>
        </div>
      </div>
    </section>

    <section class="view projects">
      <div class="ph"><div><h1>Projects</h1><p><span><span class="dot crit"></span>2 need attention</span><span><span class="dot run"></span>2 checks running</span>${fresh('just now')}</p></div><button class="btn line">${ic('plus')}Add project</button></div>
      ${card(ado,'License Service','INT deploy failed · #881 stopped at integration tests','flash',['crit','#881 failed'],['warn','1 open'],['off',':7071'],['ok','v2.13.1'])}
      ${card(ado,'Billing API','Failed requests 4.2% since 10:14','',['ok','main #2148 · 41 m'],['warn','2 open'],['run',':5001'],['crit','v2.30.4 · alert'])}
      ${card(ado,'Customer Portal','#1093 deploying to INT · 2 m','moved',['run','#1093 running · 2 m'],['run','5 open'],['run',':3000'],['ok','v5.8.2'])}
      ${card(gh,'Webhook Relay','contoso/webhook-relay · main','',['ok','main · passing'],['run','1 open'],['run',':8080'],['ok','v0.9.5'])}
      ${card(ado,'Identity Gateway','contoso/identity-gateway · main','',['ok','main #612 · 2 h'],['ok','4 open'],['off',':5100'],['ok','v3.4.0'])}
      ${card(gh,'Status Page','contoso/status-page · main','',['ok','main · passing'],['ok','1 open'],['off','not set'],['ok','88 ms'])}
    </section>
    ${L.overlay[view]||''}
  </div>
  <div class="status"><span>${L.statusLeft}</span><span>Synthetic data · mockup</span></div>
</div></div>`);

function card(fav,name,why,cls,pipe,prs,local,prod){
  const c=(label,[s,t])=>`<div class="cc"><small>${label}</small><div class="c"><span class="dot ${s}"></span><span>${t}</span></div></div>`;
  return `<div class="card ${cls}"><div class="nm">${fav}<div style="min-width:0"><b>${name}</b><span class="why">${why}</span></div></div>${c('Pipelines',pipe)}${c('PRs',prs)}${c('Local',local)}${c('PROD',prod)}</div>`;
}
