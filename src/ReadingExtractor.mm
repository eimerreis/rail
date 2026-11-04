#import "ReadingExtractor.h"
#import "CEFBridge.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_values.h"

@interface ReadingExtractor ()
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser generation:(uint64_t)generation;
- (void)browserClosing:(uint64_t)generation;
- (void)browserClosed:(uint64_t)generation;
- (void)loadingFinished:(uint64_t)generation;
- (void)loadStatus:(int)status generation:(uint64_t)generation;
- (void)loadFailed:(uint64_t)generation;
- (void)evaluated:(NSString *)result generation:(uint64_t)generation;
- (void)faviconURL:(NSString *)iconURL generation:(uint64_t)generation;
@end

namespace {
// Runs in the page, returns a JSON string and changes nothing there. A page could tamper with what
// this sees, but the result is only ever data: the reader draws it natively and runs none of it.
const char *const ExtractionScript = R"JS((() => {
  const skipTags = new Set(['SCRIPT','STYLE','NOSCRIPT','NAV','ASIDE','FOOTER','HEADER','FORM','BUTTON','SVG','IFRAME','CANVAS','TEMPLATE','SELECT','INPUT','TEXTAREA','OBJECT','EMBED','VIDEO','AUDIO','MENU','DIALOG']);
  const noise = /(^|[-_\s])(comments?|share|sharing|social|related|recommend\w*|promo|sidebar|newsletter|subscribe|cookie|banner|advert\w*|ads?|footer|masthead|breadcrumbs?|menu|nav|pagination|toc)([-_\s]|$)/i;
  // Back matter is long and full of sentences, so it has to be ruled out by name, not by size.
  const backMatter = /(^|[-_\s])(references?|reflist|citations?|footnotes?|bibliography|endnotes|navbox|catlinks|mw-references-wrap)([-_\s]|$)/i;
  const clean = s => s.replace(/\s+/g, ' ');
  const web = u => { try { const p = new URL(u, document.baseURI); return /^https?:$/.test(p.protocol) ? p.href : ''; } catch { return ''; } };
  const meta = (...names) => { for (const n of names) { const e = document.querySelector(`meta[property="${n}"],meta[name="${n}"]`); const c = e && e.getAttribute('content'); if (c && c.trim()) return c.trim(); } return ''; };
  const hidden = e => { if (e.hidden || e.getAttribute('aria-hidden') === 'true') return true; const s = getComputedStyle(e); return s.display === 'none' || s.visibility === 'hidden'; };
  const textOf = e => clean(e.textContent || '').trim();
  const linkDensity = e => { const t = textOf(e).length; if (!t) return 0; let l = 0; for (const a of e.querySelectorAll('a')) l += textOf(a).length; return l / t; };
  const names = e => `${typeof e.className === 'string' ? e.className : ''} ${e.id || ''}`;
  const noisy = e => backMatter.test(names(e)) || noise.test(names(e)) && (textOf(e).length < 800 || linkDensity(e) > .4);

  const scores = new Map();
  const credit = (e, n) => { if (e && e !== document.documentElement) scores.set(e, (scores.get(e) || 0) + n); };
  for (const p of document.querySelectorAll('p,pre,blockquote,li')) {
    const t = textOf(p); if (t.length < 40) continue;
    if (p.closest('nav,aside,footer,form')) continue;
    let up = false; for (let e = p.parentElement; e; e = e.parentElement) if (backMatter.test(names(e))) { up = true; break; }
    if (up) continue;
    // Lists count for less than prose: long ones are as often link collections as content.
    const n = (1 + (t.match(/[,.;]/g) || []).length * .3 + Math.min(t.length / 100, 3)) * (p.tagName === 'LI' ? .25 : 1);
    credit(p.parentElement, n); credit(p.parentElement && p.parentElement.parentElement, n / 2);
  }
  let root = null, best = 0;
  for (const [e, s] of scores) {
    if (e === document.body || skipTags.has(e.tagName) || hidden(e) || noisy(e)) continue;
    let v = s * (1 - linkDensity(e));
    if (e.matches('article,main,[role=main],[itemprop=articleBody]')) v *= 1.5;
    if (v > best) { best = v; root = e; }
  }
  const declared = root && root.closest('article,[itemprop=articleBody]');
  if (declared && textOf(declared).length < textOf(root).length * 2) root = declared;
  root = root || document.querySelector('article,main,[role=main]') || document.body;
  // An article split into sections scores highest on its longest one, so take in the sections around it.
  const prose = e => { let n = 0; for (const p of e.querySelectorAll('p,pre,blockquote')) { if (p.closest('nav,aside,footer,form')) continue; let back = false; for (let u = p.parentElement; u && u !== e; u = u.parentElement) if (backMatter.test(names(u))) { back = true; break; } if (!back) n += textOf(p).length; } return n; };
  while (root !== document.body && root.parentElement && root.parentElement !== document.body && root.parentElement !== document.documentElement) {
    const up = root.parentElement;
    if (noisy(up) || linkDensity(up) > .5 || root.tagName !== 'SECTION' && prose(up) < prose(root) * 1.25) break;
    root = up;
  }

  const runsOf = (node) => {
    const runs = [];
    const push = (text, style) => {
      if (!text) return;
      const last = runs[runs.length - 1];
      if (last && last.href === style.href && last.em === style.em && last.strong === style.strong && last.code === style.code) last.text += text;
      else runs.push({ text, ...style });
    };
    const walk = (n, style) => {
      for (const c of n.childNodes) {
        if (c.nodeType === 3) { push(style.pre ? c.nodeValue : c.nodeValue.replace(/\s+/g, ' '), style); continue; }
        if (c.nodeType !== 1 || skipTags.has(c.tagName) && c.tagName !== 'BUTTON' || hidden(c)) continue;
        if (c.tagName === 'BR') { push('\n', style); continue; }
        const next = { ...style };
        if (c.tagName === 'A') { const h = web(c.getAttribute('href') || ''); if (h) next.href = h; }
        if (c.tagName === 'EM' || c.tagName === 'I') next.em = true;
        if (c.tagName === 'STRONG' || c.tagName === 'B') next.strong = true;
        if (c.tagName === 'CODE' || c.tagName === 'KBD' || c.tagName === 'SAMP') next.code = true;
        walk(c, next);
      }
    };
    walk(node, {});
    if (runs.length) { runs[0].text = runs[0].text.replace(/^\s+/, ''); runs[runs.length - 1].text = runs[runs.length - 1].text.replace(/\s+$/, ''); }
    return runs.filter(r => r.text);
  };
  const blocks = [];
  const blockTags = new Set(['P','H1','H2','H3','H4','H5','H6','UL','OL','LI','PRE','BLOCKQUOTE','FIGURE','IMG','PICTURE','TABLE','DIV','SECTION','ARTICLE','MAIN','DL','HR','FIGCAPTION']);
  const hasBlockChild = e => { for (const c of e.children) if (blockTags.has(c.tagName) && !hidden(c)) return true; return false; };
  const addImage = img => {
    const src = web(img.currentSrc || img.getAttribute('data-src') || img.getAttribute('data-lazy-src') || img.getAttribute('src') || '');
    if (!src) return;
    const w = img.naturalWidth || +img.getAttribute('width') || 0, h = img.naturalHeight || +img.getAttribute('height') || 0;
    if (w && w < 64 || h && h < 64) return;
    blocks.push({ t: 'img', src, alt: img.getAttribute('alt') || '', w, h });
  };
  const addRuns = (t, e, extra) => { const runs = runsOf(e); if (runs.length) blocks.push({ t, runs, ...extra }); };
  const visit = e => {
    if (blocks.length > 3000) return;
    for (const c of e.childNodes) {
      if (c.nodeType === 3) { if (c.nodeValue.trim().length > 40) blocks.push({ t: 'p', runs: [{ text: clean(c.nodeValue).trim() }] }); continue; }
      if (c.nodeType !== 1 || skipTags.has(c.tagName) || hidden(c) || noisy(c)) continue;
      const tag = c.tagName;
      if (/^H[1-6]$/.test(tag)) addRuns('h', c, { l: +tag[1] });
      else if (tag === 'P') { const imgs = c.querySelectorAll('img'); if (imgs.length && !textOf(c)) imgs.forEach(addImage); else addRuns('p', c); }
      else if (tag === 'PRE') { const text = c.textContent.replace(/\s+$/, ''); if (text) blocks.push({ t: 'pre', text }); }
      else if (tag === 'BLOCKQUOTE') { if (hasBlockChild(c)) { for (const q of c.children) if (!hidden(q)) addRuns('q', q); } else addRuns('q', c); }
      else if (tag === 'UL' || tag === 'OL') {
        if (linkDensity(c) > .7 && c.children.length > 3) continue;
        let n = 0;
        for (const li of c.children) { if (li.tagName !== 'LI' || hidden(li)) continue; n++; addRuns('li', li, tag === 'OL' ? { n } : {}); }
      }
      else if (tag === 'IMG') addImage(c);
      else if (tag === 'PICTURE') { const i = c.querySelector('img'); if (i) addImage(i); }
      else if (tag === 'FIGURE') { const i = c.querySelector('img'); if (i) addImage(i); const k = c.querySelector('figcaption'); if (k) addRuns('cap', k); else if (!i) visit(c); }
      else if (tag === 'TABLE') { for (const r of c.querySelectorAll('tr')) { const text = [...r.children].map(textOf).filter(Boolean).join('  ·  '); if (text) blocks.push({ t: 'p', runs: [{ text }] }); } }
      else if (hasBlockChild(c)) visit(c);
      else if (textOf(c).length > 20 && linkDensity(c) < .6) addRuns('p', c);
    }
  };
  visit(root);

  const h1 = document.querySelector('article h1,main h1,h1');
  const title = meta('og:title','twitter:title') || (h1 && textOf(h1)) || document.title.trim();
  const firstText = b => (b.runs || []).map(r => r.text).join('');
  const repeatsTitle = h => { const a = firstText(h).toLowerCase().replace(/\W+/g, ''), b = title.toLowerCase().replace(/\W+/g, ''); return a === b || a.length > 8 && b.includes(a); };
  while (blocks.length && blocks[0].t === 'h' && repeatsTitle(blocks[0])) blocks.shift();
  const words = blocks.reduce((sum, b) => sum + (b.text || firstText(b)).split(/\s+/).filter(Boolean).length, 0);
  const time = document.querySelector('time[datetime]');
  const password = [...document.querySelectorAll('input[type=password]')].some(i => !hidden(i));
  return JSON.stringify({
    title, words, blocks,
    site: meta('og:site_name'),
    byline: meta('author','article:author').replace(/^https?:.*/, ''),
    published: meta('article:published_time','date') || (time ? time.getAttribute('datetime') : ''),
    login: password && words < 300,
  });
})())JS";
constexpr int EnoughWords = 80, MaxAttempts = 3;
NSString *S(const CefString &s) { return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @""; }

class FaviconReader final : public CefDownloadImageCallback {
 public:
  explicit FaviconReader(void (^done)(NSData *)) : done_(done) {}
  void OnDownloadImageFinished(const CefString &, int, CefRefPtr<CefImage> image) override {
    if (!image || image->IsEmpty()) return;
    int width = 0, height = 0; CefRefPtr<CefBinaryValue> data = image->GetAsPNG(2.0f,true,width,height);
    if (!data || !data->GetSize()) return;
    NSMutableData *bytes = [NSMutableData dataWithLength:data->GetSize()]; data->GetData(bytes.mutableBytes,bytes.length,0); done_(bytes);
  }
 private:
  void (^done_)(NSData *);
  IMPLEMENT_REFCOUNTING(FaviconReader);
};

class ExtractionClient final : public CefClient, public CefLifeSpanHandler, public CefLoadHandler, public CefRequestHandler,
  public CefJSDialogHandler, public CefDisplayHandler, public CefFocusHandler, public CefDevToolsMessageObserver {
 public:
  ExtractionClient(ReadingExtractor *owner, uint64_t generation) : owner_(owner), generation_(generation) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  // These pages are never shown, so they never get the keyboard.
  bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource) override { return true; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { [owner_ browserCreated:browser generation:generation_]; }
  bool DoClose(CefRefPtr<CefBrowser>) override { [owner_ browserClosing:generation_]; return true; }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override { [owner_ browserClosed:generation_]; }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString &, const CefString &, WindowOpenDisposition, bool, const CefPopupFeatures &,
      CefWindowInfo &, CefRefPtr<CefClient> &, CefBrowserSettings &, CefRefPtr<CefDictionaryValue> &, bool *) override { return true; }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool loading, bool, bool) override { if (!loading) [owner_ loadingFinished:generation_]; }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int status) override { if (frame->IsMain()) [owner_ loadStatus:status generation:generation_]; }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code, const CefString &, const CefString &) override {
    if (frame->IsMain() && code != ERR_ABORTED) [owner_ loadFailed:generation_];
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool, bool) override {
    return frame->IsMain() && !RailNavigationAllowed(request->GetURL());
  }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus, int, const CefString &) override { [owner_ loadFailed:generation_]; }
  bool OnJSDialog(CefRefPtr<CefBrowser>, const CefString &, JSDialogType, const CefString &, const CefString &, CefRefPtr<CefJSDialogCallback>, bool &suppress) override { suppress = true; return false; }
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString &, bool, CefRefPtr<CefJSDialogCallback> callback) override { callback->Continue(true,CefString()); return true; }
  void OnFaviconURLChange(CefRefPtr<CefBrowser>, const std::vector<CefString> &urls) override { if (!urls.empty()) [owner_ faviconURL:S(urls.front()) generation:generation_]; }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int, bool success, const void *result, size_t size) override {
    NSString *value = nil;
    if (success && result && size) {
      id parsed = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:result length:size] options:0 error:nil];
      id inner = [parsed isKindOfClass:NSDictionary.class] ? parsed[@"result"] : nil;
      if ([inner isKindOfClass:NSDictionary.class] && !parsed[@"exceptionDetails"] && [inner[@"value"] isKindOfClass:NSString.class]) value = inner[@"value"];
    }
    [owner_ evaluated:value generation:generation_];
  }
 private:
  __weak ReadingExtractor *owner_;
  uint64_t generation_;
  IMPLEMENT_REFCOUNTING(ExtractionClient);
};
}

@interface ReadingExtractionJob : NSObject
@property(nonatomic, copy) NSString *url, *key, *session;
@property(nonatomic, copy) void (^completion)(NSDictionary *);
@end
@implementation ReadingExtractionJob {
  @public CefRefPtr<CefRequestContext> context;
}
@end

@implementation ReadingExtractor {
  __weak NSView *_host;
  NSMutableArray<ReadingExtractionJob *> *_queue;
  ReadingExtractionJob *_job;
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<ExtractionClient> _client;
  CefRefPtr<CefRegistration> _observer;
  NSView *_container;
  NSTimer *_timeout, *_wait;
  uint64_t _generation;
  int _attempts, _status;
  BOOL _failed, _closing, _finished, _evaluating, _shuttingDown;
  void (^_shutdownDone)(void);
  NSDictionary *_lastArticle;
  NSString *_activeSessionWhileClosing;
}
- (instancetype)initWithHost:(NSView *)host {
  if ((self = [super init])) { _host = host; _queue = [NSMutableArray array]; }
  return self;
}
- (NSString *)activeSession { return _container ? _activeSessionWhileClosing : nil; }
- (BOOL)isExtracting:(NSString *)key {
  if ([_job.key isEqual:key] && !_finished) return YES;
  for (ReadingExtractionJob *job in _queue) if ([job.key isEqual:key]) return YES;
  return NO;
}
- (void)extract:(NSString *)url key:(NSString *)key context:(CefRefPtr<CefRequestContext>)context session:(NSString *)session urgent:(BOOL)urgent completion:(void (^)(NSDictionary *))completion {
  if (_shuttingDown || !context) { completion(nil); return; }
  if ([_job.key isEqual:key] && !_finished) return;
  for (NSUInteger i=0;i<_queue.count;i++) if ([_queue[i].key isEqual:key]) {
    ReadingExtractionJob *queued = _queue[i];
    if (urgent) { [_queue removeObjectAtIndex:i]; [_queue insertObject:queued atIndex:0]; }
    return;
  }
  ReadingExtractionJob *job = [[ReadingExtractionJob alloc] init];
  job.url = url; job.key = key; job.session = session; job.completion = completion; job->context = context;
  if (urgent) [_queue insertObject:job atIndex:0]; else [_queue addObject:job];
  [self startNext];
}
- (void)cancel:(NSString *)key {
  for (NSUInteger i=_queue.count;i>0;i--) if ([_queue[i-1].key isEqual:key]) [_queue removeObjectAtIndex:i-1];
  if ([_job.key isEqual:key] && !_finished) { _job.completion = nil; [self finish:nil]; }
}
- (void)startNext {
  if (_job || _container || !_queue.count || _shuttingDown) return;
  NSView *host = _host; if (!host) return;
  _job = _queue.firstObject; [_queue removeObjectAtIndex:0];
  _generation++; _attempts = 0; _status = 0; _failed = _finished = _closing = _evaluating = NO; _lastArticle = nil;
  _activeSessionWhileClosing = _job.session;
  // Laid out like a normal window, so pages don't serve their narrowest layout, but never shown.
  _container = [[NSView alloc] initWithFrame:NSMakeRect(0,0,1100,800)]; _container.hidden = YES; [host addSubview:_container];
  CefWindowInfo info; info.SetAsChild((__bridge CefWindowHandle)_container,CefRect(0,0,1100,800)); info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings; settings.background_color = CefColorSetARGB(255,255,255,255);
  _client = new ExtractionClient(self,_generation);
  __weak ReadingExtractor *weak = self;
  _timeout = [NSTimer scheduledTimerWithTimeInterval:40 repeats:NO block:^(NSTimer *timer) { (void)timer; [weak timedOut]; }];
  if (!CefBrowserHost::CreateBrowser(info,_client,_job.url.UTF8String,settings,nullptr,_job->context)) { [_container removeFromSuperview]; _container = nil; _client = nullptr; [self finishWithoutBrowser]; }
}
- (void)timedOut {
  // Pages with endless background requests never finish loading; read what is there.
  if (_job && !_finished && _browser && !_evaluating) { _attempts = MaxAttempts-1; [self evaluate]; [self performSelector:@selector(stopWaiting) withObject:nil afterDelay:3]; return; }
  [self stopWaiting];
}
- (void)stopWaiting { if (_job && !_finished) [self finish:[self lastResult]]; }
// A thin result from a page that never finished loading says nothing about the page, so it counts as a failed load.
- (NSDictionary *)lastResult { return _status || [_lastArticle[@"words"] intValue] >= EnoughWords ? _lastArticle : nil; }
- (void)finishWithoutBrowser {
  [_timeout invalidate]; _timeout = nil;
  void (^completion)(NSDictionary *) = _job.completion; _job = nil; if (completion) completion(nil);
  [self startNext]; [self checkShutdown];
}
- (void)browserCreated:(CefRefPtr<CefBrowser>)browser generation:(uint64_t)generation {
  if (generation != _generation) { browser->GetHost()->CloseBrowser(true); return; }
  _browser = browser; browser->GetHost()->SetAudioMuted(true);
  _observer = browser->GetHost()->AddDevToolsMessageObserver(_client.get());
  if (_finished) browser->GetHost()->CloseBrowser(true);
}
- (void)browserClosing:(uint64_t)generation {
  if (generation != _generation) return;
  for (NSView *view in [_container.subviews copy]) [view removeFromSuperview];
}
- (void)browserClosed:(uint64_t)generation {
  if (generation != _generation) return;
  [_container removeFromSuperview]; _container = nil; _browser = nullptr; _observer = nullptr; _client = nullptr; _job = nil; _closing = NO;
  [self startNext]; [self checkShutdown];
}
- (void)loadStatus:(int)status generation:(uint64_t)generation { if (generation == _generation) _status = status; }
- (void)loadFailed:(uint64_t)generation {
  if (generation != _generation || _finished) return;
  _failed = YES; [self finish:nil];
}
- (void)loadingFinished:(uint64_t)generation {
  if (generation != _generation || _finished || _failed) return;
  [_wait invalidate]; __weak ReadingExtractor *weak = self;
  // Give scripts a moment to put the article on the page.
  _wait = [NSTimer scheduledTimerWithTimeInterval:.7 repeats:NO block:^(NSTimer *timer) { (void)timer; [weak evaluate]; }];
}
- (void)evaluate {
  if (!_browser || _finished || _evaluating) return;
  if (_status == 401 || _status == 403) { [self finish:@{@"login":@YES,@"words":@0,@"blocks":@[],@"title":@"",@"site":@"",@"byline":@"",@"published":@""}]; return; }
  if (_status >= 400) { [self finish:nil]; return; }
  _evaluating = YES; _attempts++;
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression",ExtractionScript); params->SetBool("returnByValue",true);
  if (!_browser->GetHost()->ExecuteDevToolsMethod(0,"Runtime.evaluate",params)) { _evaluating = NO; [self finish:nil]; }
}
- (void)evaluated:(NSString *)result generation:(uint64_t)generation {
  if (generation != _generation || _finished) return;
  _evaluating = NO;
  id article = result ? [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
  if (![article isKindOfClass:NSDictionary.class]) article = nil;
  if (article) _lastArticle = article;
  const BOOL enough = [article[@"words"] intValue] >= EnoughWords || [article[@"login"] boolValue];
  if (enough || _attempts >= MaxAttempts) { [self finish:[self lastResult]]; return; }
  // Script-heavy pages can still be filling in.
  [_wait invalidate]; __weak ReadingExtractor *weak = self;
  _wait = [NSTimer scheduledTimerWithTimeInterval:2 repeats:NO block:^(NSTimer *timer) { (void)timer; [weak evaluate]; }];
}
- (void)finish:(NSDictionary *)article {
  if (_finished) return;
  _finished = YES; [_timeout invalidate]; _timeout = nil; [_wait invalidate]; _wait = nil;
  void (^completion)(NSDictionary *) = _job.completion; _job.completion = nil;
  if (completion) completion(article);
  if (_browser && !_closing) { _closing = YES; _browser->GetHost()->CloseBrowser(true); }
}
- (void)faviconURL:(NSString *)iconURL generation:(uint64_t)generation {
  if (generation != _generation || !_browser || !self.onFavicon || !iconURL.length) return;
  NSString *page = _job.url; __weak ReadingExtractor *weak = self;
  _browser->GetHost()->DownloadImage(iconURL.UTF8String,true,32,false,new FaviconReader(^(NSData *png) { ReadingExtractor *strong = weak; if (strong.onFavicon) strong.onFavicon(page,png); }));
}
- (void)checkShutdown {
  if (!_shuttingDown || _container || _job || !_shutdownDone) return;
  void (^done)(void) = _shutdownDone; _shutdownDone = nil; done();
}
- (void)shutdown:(void (^)(void))done {
  _shuttingDown = YES; _shutdownDone = [done copy]; [_queue removeAllObjects];
  if (_job && !_finished) { _job.completion = nil; [self finish:nil]; }
  [self checkShutdown];
}
@end
