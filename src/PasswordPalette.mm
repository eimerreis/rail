#import "PasswordPalette.h"
#import "PasswordService.h"
#import "NativeViews.h"

@interface PasswordPanel : NSPanel
@property(nonatomic, copy) void (^dismiss)(void);
@end
@implementation PasswordPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)cancelOperation:(id)sender { (void)sender; if (_dismiss) _dismiss(); }
@end

@implementation PasswordPalette {
  PasswordService *_service;
  __weak NSWindow *_parent;
  PasswordPanel *_panel;
  RailPanel *_root, *_results;
  NSScrollView *_scroll;
  NSTextField *_search, *_account, *_titleField, *_username, *_status;
  NSSecureTextField *_password;
  NSPopUpButton *_vaultPicker;
  NSStepper *_lengthControl;
  NSButton *_symbols;
  NSArray<NSDictionary *> *_items, *_vaults, *_filtered;
  NSMutableArray<RailButton *> *_rows;
  NSMutableArray<NSControl *> *_controls;
  RailButton *_fillButton, *_openButton;
  NSAlert *_crossSiteConfirmation;
  NSAlert *_itemLinkSetup;
  NSTextField *_itemLinkField;
  NSString *_fixtureOpenedURL;
  NSString *_fixtureAccountLink;
  NSString *_url, *_title, *_message, *_query, *_draftTitle, *_draftUsername, *_draftPassword, *_draftVault;
  NSString *_announcedMessage;
  RailPasswordFill _fill;
  NSInteger _selected, _length, _offset, _total;
  BOOL _loadingLogins, _searchPending, _forceRefresh;
  BOOL _newLogin, _busy, _saving, _saved, _uncertain, _canFill, _closed, _symbolsEnabled;
}
- (instancetype)initWithService:(PasswordService *)service parent:(NSWindow *)parent url:(NSString *)url title:(NSString *)title fill:(RailPasswordFill)fill {
  if ((self = [super init])) {
    _service = service; _parent = parent; _url = [url copy] ?: @""; _title = [title copy] ?: @""; _fill = [fill copy];
    _items = @[]; _vaults = @[]; _query = @""; _length = 24; _symbolsEnabled = YES; _canFill = _url.length > 0;
    _draftTitle = [NSURLComponents componentsWithString:_url].host ?: _title;
    _draftUsername = @""; _draftPassword = @"";
    _panel = [[PasswordPanel alloc] initWithContentRect:NSMakeRect(0,0,560,590) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    _panel.releasedWhenClosed = NO; _panel.hasShadow = YES; _panel.opaque = NO; _panel.backgroundColor = NSColor.clearColor;
    _panel.title = @"1Password"; _panel.delegate = self; _panel.hidesOnDeactivate = NO;
    _panel.accessibilityLabel = @"1Password command palette";
    __weak PasswordPalette *weak = self; _panel.dismiss = ^{ [weak close]; };
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(themeChanged:) name:RailThemeDidChangeNotification object:nil];
  }
  return self;
}
- (NSPanel *)panel { return _panel; }
- (BOOL)handleShortcut:(NSEvent *)event {
  if (!_panel.isVisible || event.window!=_panel || event.type!=NSEventTypeKeyDown) return NO;
  if (_panel.attachedSheet) return NO;
  NSEventModifierFlags flags=event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagShift|NSEventModifierFlagOption|NSEventModifierFlagControl);
  if (flags!=NSEventModifierFlagCommand) return NO;
  if ([event.charactersIgnoringModifiers.lowercaseString isEqual:@"n"]) { [self newLogin]; return YES; }
  if (event.keyCode==36) { if (_newLogin && _canFill) [self saveAndFill:YES]; else if (!_newLogin) [self fillSelected]; return YES; }
  return NO;
}
- (void)themeChanged:(NSNotification *)note { (void)note; if (!_closed) { [self captureDraft]; [self render]; } }
- (void)show {
  _closed = NO; NSRect f = _parent.frame;
  [_panel setFrameOrigin:NSMakePoint(NSMidX(f)-280,NSMaxY(f)-660)];
  [_parent addChildWindow:_panel ordered:NSWindowAbove];
  [self render]; [_panel makeKeyAndOrderFront:nil];
  if (_service.connectedAccount.length) [self loadLogins];
}
- (void)announce:(NSString *)message {
  if (!message.length) return;
  NSAccessibilityPostNotificationWithUserInfo(_panel,NSAccessibilityAnnouncementRequestedNotification,
    @{NSAccessibilityAnnouncementKey:message,NSAccessibilityPriorityKey:@(NSAccessibilityPriorityMedium)});
}
- (void)close {
  if (_saving) {
    [_service stop]; _busy = NO; _saving = NO; _uncertain = YES;
    _message = @"Save interrupted. Check 1Password before saving again."; [self render]; return;
  }
  _closed = YES; [NSObject cancelPreviousPerformRequestsWithTarget:self]; _searchPending=NO;
  if (_panel.attachedSheet) [_panel endSheet:_panel.attachedSheet returnCode:NSAlertFirstButtonReturn];
  if (_busy) [_service stop];
  _items=@[]; _filtered=@[];
  _draftPassword = @""; _password.stringValue = @""; _fill = nil;
  [_parent removeChildWindow:_panel]; [_panel orderOut:nil]; [_parent makeKeyWindow];
}
- (void)invalidatePage {
  if (_closed) return; _canFill = NO;
  _message = _newLogin ? @"Page changed. You can still save this login to 1Password." : @"Page changed. Reopen 1Password to fill the current page.";
  [self captureDraft]; [self render];
}
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor *)color {
  NSTextField *v = RailLabel(text,size,weight,color); v.frame = frame; [_root addSubview:v]; return v;
}
- (RailButton *)button:(NSString *)title frame:(NSRect)frame primary:(BOOL)primary action:(void (^)(void))action {
  RailButton *v = RailAction(title,@"",title,action); v.frame = frame; v.centered = YES; v.cornerRadius = 8;
  v.font = RailFont(13,NSFontWeightSemibold); v.normalFill = RailTint(primary ? RailRoleAccent : RailRoleSunken);
  v.hoverFill = RailTint(primary ? RailRoleSelectedInk : RailRoleContentHover); v.ink = RailTint(primary ? RailRoleOnAccent : RailRoleInk);
  v.enabled = !_busy; [_root addSubview:v]; [_controls addObject:v]; return v;
}
- (NSTextField *)field:(NSString *)value placeholder:(NSString *)placeholder frame:(NSRect)frame secure:(BOOL)secure {
  NSTextField *v = secure ? [[NSSecureTextField alloc] initWithFrame:frame] : [[NSTextField alloc] initWithFrame:frame];
  v.stringValue = value ?: @""; v.placeholderString = placeholder; v.font = [NSFont systemFontOfSize:14];
  v.textColor = RailInk(); v.backgroundColor = RailTint(RailRoleField); v.bezelStyle = NSTextFieldRoundedBezel;
  v.delegate = self; v.enabled = !_busy && !_saved && !_uncertain; v.accessibilityLabel = placeholder;
  [_root addSubview:v]; [_controls addObject:v]; return v;
}
- (void)captureDraft {
  if (_titleField) _draftTitle = _titleField.stringValue;
  if (_username) _draftUsername = _username.stringValue;
  if (_password) _draftPassword = _password.stringValue;
  if (_vaultPicker.selectedItem.representedObject) _draftVault = _vaultPicker.selectedItem.representedObject;
}
- (void)render {
  NSTextView *editor=(NSTextView *)_search.currentEditor;
  NSRange selection=editor ? editor.selectedRange : NSMakeRange(_query.length,0);
  _panel.appearance = RailThemeAppearance();
  _root = [[RailPanel alloc] initWithFrame:NSMakeRect(0,0,560,590)]; _root.fill = RailTint(RailRoleRaised); _root.wantsLayer = YES;
  _root.layer.cornerRadius = 16; _root.layer.masksToBounds = YES; _root.layer.borderWidth = 1; _root.layer.borderColor = RailLine().CGColor;
  _panel.contentView = _root; _controls = NSMutableArray.array;
  _titleField = nil; _username = nil; _password = nil; _vaultPicker = nil; _search = nil; _account = nil;
  _fillButton=nil; _openButton=nil; _results=nil;
  __weak PasswordPalette *weak = self;
  NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(24,25,24,24)]; icon.image = RailSymbol(@"key.fill",22); icon.contentTintColor = RailTint(RailRoleAccent); [_root addSubview:icon];
  [self label:@"1Password" frame:NSMakeRect(60,21,400,27) size:20 weight:NSFontWeightBold color:RailInk()];
  NSString *host = [NSURLComponents componentsWithString:_url].host ?: (_service.connectedAccount.length ? @"Search across all vaults" : @"Connect your account");
  [self label:host frame:NSMakeRect(60,51,420,20) size:13 weight:NSFontWeightRegular color:RailMuted()];
  RailButton *close = [self button:@"Esc" frame:NSMakeRect(496,25,40,28) primary:NO action:^{ [weak close]; }]; close.enabled = YES; close.accessibilityLabel = @"Close 1Password";
  if (!_service.connectedAccount.length) {
    [self label:@"Connect to 1Password" frame:NSMakeRect(24,112,510,30) size:23 weight:NSFontWeightBold color:RailInk()];
    NSTextField *intro = [self label:@"Use the 1Password app on this Mac to approve access to your account." frame:NSMakeRect(24,153,510,48) size:14 weight:NSFontWeightRegular color:RailMuted()]; intro.maximumNumberOfLines = 2; intro.lineBreakMode=NSLineBreakByWordWrapping;
    [self label:@"Account name or ID" frame:NSMakeRect(24,222,510,20) size:13 weight:NSFontWeightSemibold color:RailInk()];
    _account = [self field:_service.fixtureOrigin.length ? @"Rail Test" : [NSUserDefaults.standardUserDefaults stringForKey:@"OnePasswordAccount"] placeholder:@"As shown in the 1Password app" frame:NSMakeRect(24,250,512,36) secure:NO];
    [self button:@"Connect 1Password" frame:NSMakeRect(24,306,512,40) primary:YES action:^{ [weak connect]; }];
    NSTextField *access = [self label:@"1Password grants temporary access to this account. Lock 1Password or disconnect here to end Rail’s access." frame:NSMakeRect(24,369,512,64) size:13 weight:NSFontWeightRegular color:RailMuted()]; access.maximumNumberOfLines = 3; access.lineBreakMode=NSLineBreakByWordWrapping;
    [_panel makeFirstResponder:_account];
  } else {
    RailButton *fill = [self button:@"Search items" frame:NSMakeRect(24,91,250,34) primary:!_newLogin action:^{ PasswordPalette *s=weak; if (!s || !s->_newLogin) return; [s captureDraft]; s->_newLogin=NO; [s loadLogins]; }];
    RailButton *create = [self button:@"New login" frame:NSMakeRect(286,91,250,34) primary:_newLogin action:^{ [weak newLogin]; }];
    create.keyEquivalent=@"n"; create.keyEquivalentModifierMask=NSEventModifierFlagCommand; create.toolTip=@"New login (⌘ N)";
    fill.enabled = create.enabled = !_busy;
    if (_newLogin) [self renderNewLogin]; else [self renderLogins];
    RailButton *connection = [self button:_uncertain ? @"Open 1Password" : @"Disconnect" frame:NSMakeRect(386,551,150,26) primary:NO action:^{ PasswordPalette *s=weak; if (!s) return; if (s->_uncertain) { [s openOnePassword]; return; } [s disconnect]; }]; connection.font = RailFont(12,NSFontWeightMedium);
    [self label:[NSString stringWithFormat:@"1Password · %@",_service.connectedAccount] frame:NSMakeRect(24,555,350,19) size:12 weight:NSFontWeightRegular color:RailMuted()];
  }
  _status = [self label:_message ?: @"" frame:NSMakeRect(24,493,512,48) size:13 weight:NSFontWeightRegular color:RailMuted()]; _status.maximumNumberOfLines = 3; _status.lineBreakMode=NSLineBreakByWordWrapping;
  if (_busy) {
    NSProgressIndicator *progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(516,54,16,16)]; progress.style = NSProgressIndicatorStyleSpinning; [progress startAnimation:nil]; [_root addSubview:progress];
  }
  if (![_announcedMessage isEqual:_message]) { _announcedMessage=[_message copy]; [self announce:_message]; }
  if (_search.currentEditor && NSMaxRange(selection)<=_query.length) ((NSTextView *)_search.currentEditor).selectedRange=selection;
}
- (void)renderLogins {
  _search = [self field:_query placeholder:@"Search all items" frame:NSMakeRect(24,143,512,36) secure:NO];
  _search.enabled = !_busy || _loadingLogins;
  _search.toolTip=@"Search names, login usernames, websites, vaults, categories and tags";
  __weak PasswordPalette *weak = self;
  NSString *count=_total ? [NSString stringWithFormat:@"%ld–%ld of %ld items",(long)_offset+1,(long)(_offset+_items.count),(long)_total] : @"All vaults";
  [self label:count frame:NSMakeRect(24,187,245,20) size:12 weight:NSFontWeightRegular color:RailMuted()];
  RailButton *previous=[self button:@"←" frame:NSMakeRect(330,183,32,26) primary:NO action:^{ PasswordPalette *s=weak; if (s) { s->_offset=MAX(0,s->_offset-40); [s loadLogins]; } }]; previous.enabled=!_busy&&_offset>0; previous.accessibilityLabel=@"Previous results";
  RailButton *next=[self button:@"→" frame:NSMakeRect(369,183,32,26) primary:NO action:^{ PasswordPalette *s=weak; if (s) { s->_offset+=40; [s loadLogins]; } }]; next.enabled=!_busy&&_offset+(NSInteger)_items.count<_total; next.accessibilityLabel=@"Next results";
  [self button:@"Refresh" frame:NSMakeRect(436,183,100,26) primary:NO action:^{ [weak refreshLogins]; }];
  _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16,218,528,208)]; _scroll.drawsBackground = NO; _scroll.hasVerticalScroller = YES;
  _results = [[RailPanel alloc] init]; _results.fill = RailTint(RailRoleRaised); _scroll.documentView = _results; [_root addSubview:_scroll];
  [self updateResults];
  _fillButton = [self button:@"Fill selected login" frame:NSMakeRect(24,442,332,36) primary:YES action:^{ [weak fillSelected]; }];
  _openButton = [self button:@"Open in 1Password" frame:NSMakeRect(368,442,168,36) primary:NO action:^{ [weak openSelectedItem]; }];
  [self updateSelectionAction];
  [_panel makeFirstResponder:_search];
}
- (void)updateResults {
  for (NSView *v in _results.subviews.copy) [v removeFromSuperview];
  _filtered = _items; _selected = MIN(MAX(0,_selected),(NSInteger)_filtered.count-1); _rows = NSMutableArray.array;
  _results.frame = NSMakeRect(0,0,512,MAX(208,_filtered.count*65));
  if (!_filtered.count) {
    NSTextField *empty = RailLabel(_busy ? @"Loading your items…" : @"No matching items",16,NSFontWeightSemibold,RailInk()); empty.frame=NSMakeRect(16,32,475,25); [_results addSubview:empty];
    NSTextField *hint = RailLabel(@"Creating an account? Choose New login above.",13,NSFontWeightRegular,RailMuted()); hint.frame=NSMakeRect(16,65,475,21); [_results addSubview:hint];
    __weak PasswordPalette *weak=self;
    RailButton *open=[self button:@"Open 1Password" frame:NSMakeRect(16,105,230,32) primary:NO action:^{ [weak openOnePassword]; }];
    RailButton *refresh=[self button:@"Refresh" frame:NSMakeRect(258,105,230,32) primary:NO action:^{ [weak refreshLogins]; }];
    [_results addSubview:open]; [_results addSubview:refresh];
  }
  __weak PasswordPalette *weak = self;
  [_filtered enumerateObjectsUsingBlock:^(NSDictionary *item, NSUInteger index, BOOL *stop) {
    (void)stop; PasswordPalette *s=weak; if (!s) return;
    RailButton *row = RailAction(@"",@"",item[@"title"],^{ PasswordPalette *p=weak; if (p) { p->_selected=index; [p highlightSelection]; } });
    NSString *category=[s categoryTitle:item[@"category"]];
    NSArray *websites=[item[@"websites"] isKindOfClass:NSArray.class] ? item[@"websites"] : @[];
    NSString *context=[item[@"matchesSite"] boolValue] ? @"This website" : (websites.count ? [NSURLComponents componentsWithString:websites[0]].host : category);
    row.accessibilityLabel=[NSString stringWithFormat:@"%@, %@, %@, %@",item[@"title"],[item[@"username"] length] ? item[@"username"] : category,item[@"vaultTitle"],context];
    row.onDoubleClick = ^{ [weak fillSelected]; }; row.frame=NSMakeRect(0,index*65,512,61); row.cornerRadius=8; row.enabled=!s->_busy;
    NSTextField *title = RailLabel(item[@"title"],14,NSFontWeightSemibold,RailInk()); title.frame=NSMakeRect(14,8,475,21); [row addSubview:title];
    NSString *detail = [NSString stringWithFormat:@"%@  ·  %@",[item[@"username"] length] ? item[@"username"] : category,item[@"vaultTitle"]];
    if (![context isEqual:category]) detail=[detail stringByAppendingFormat:@"  ·  %@",context];
    NSTextField *sub = RailLabel(detail,12,NSFontWeightRegular,RailMuted()); sub.frame=NSMakeRect(14,33,475,18); [row addSubview:sub];
    [s->_results addSubview:row]; [s->_rows addObject:row];
  }];
  [self highlightSelection];
  _search.accessibilityHelp=[NSString stringWithFormat:@"%ld matching items. Use up and down arrows to choose. Return fills logins or opens other items in 1Password.",(long)_total];
}
- (NSString *)categoryTitle:(NSString *)category {
  NSDictionary *names=@{@"SecureNote":@"Secure note",@"CreditCard":@"Credit card",@"ApiCredentials":@"API credentials",@"SshKey":@"SSH key",@"BankAccount":@"Bank account",@"SoftwareLicense":@"Software license",@"DriverLicense":@"Driver license",@"SocialSecurityNumber":@"Social security number",@"CryptoWallet":@"Crypto wallet",@"MedicalRecord":@"Medical record",@"OutdoorLicense":@"Outdoor license"};
  return names[category] ?: category ?: @"Item";
}
- (void)updateSelectionAction {
  NSDictionary *item=_selected>=0&&_selected<(NSInteger)_filtered.count ? _filtered[_selected] : nil;
  BOOL fill=item && [item[@"category"] isEqual:@"Login"] && _canFill;
  _fillButton.title=fill ? @"Fill selected login" : @"Open in 1Password";
  _fillButton.accessibilityLabel=_fillButton.title;
  _fillButton.enabled=item && !_busy && !_searchPending;
  _fillButton.frame=NSMakeRect(24,442,fill ? 332 : 512,36);
  _openButton.hidden=!fill; _openButton.enabled=_fillButton.enabled;
}
- (void)highlightSelection {
  [_rows enumerateObjectsUsingBlock:^(RailButton *row, NSUInteger index, BOOL *stop) {
    (void)stop; BOOL selected=(NSInteger)index==self->_selected; row.normalFill=RailTint(selected ? RailRoleSelected : RailRoleRaised); row.hoverFill=RailTint(RailRoleContentHover); row.needsDisplay=YES;
    row.accessibilityValue=selected ? @"Selected" : @"Not selected";
  }];
  if (_selected>=0 && _selected<(NSInteger)_rows.count) { [_results scrollRectToVisible:_rows[_selected].frame]; [self announce:[NSString stringWithFormat:@"Selected %@",_rows[_selected].accessibilityLabel]]; }
  [self updateSelectionAction];
}
- (void)renderNewLogin {
  [self label:@"Login name" frame:NSMakeRect(24,142,512,19) size:12 weight:NSFontWeightSemibold color:RailInk()];
  _titleField=[self field:_draftTitle placeholder:@"Login name" frame:NSMakeRect(24,165,512,32) secure:NO];
  [self label:@"Username or email" frame:NSMakeRect(24,210,512,19) size:12 weight:NSFontWeightSemibold color:RailInk()];
  _username=[self field:_draftUsername placeholder:@"Username or email" frame:NSMakeRect(24,233,512,32) secure:NO];
  [self label:@"Password" frame:NSMakeRect(24,278,512,19) size:12 weight:NSFontWeightSemibold color:RailInk()];
  _password=(NSSecureTextField *)[self field:_draftPassword placeholder:@"Generate or enter a password" frame:NSMakeRect(24,301,350,32) secure:YES];
  __weak PasswordPalette *weak=self;
  RailButton *generate=[self button:@"Generate again" frame:NSMakeRect(386,301,150,32) primary:NO action:^{ [weak generate]; }]; generate.enabled=!_busy&&!_saved&&!_uncertain;
  [self label:[NSString stringWithFormat:@"%ld characters",(long)_length] frame:NSMakeRect(24,347,128,22) size:12 weight:NSFontWeightRegular color:RailMuted()];
  _lengthControl=[[NSStepper alloc] initWithFrame:NSMakeRect(146,344,19,25)]; _lengthControl.minValue=8; _lengthControl.maxValue=100; _lengthControl.integerValue=_length; _lengthControl.target=self; _lengthControl.action=@selector(recipeChanged:); _lengthControl.enabled=!_busy&&!_saved; _lengthControl.accessibilityLabel=@"Generated password length"; [_root addSubview:_lengthControl];
  _symbols=[NSButton checkboxWithTitle:@"Symbols" target:self action:@selector(recipeChanged:)]; _symbols.frame=NSMakeRect(190,344,118,25); _symbols.state=_symbolsEnabled ? NSControlStateValueOn : NSControlStateValueOff; _symbols.enabled=!_busy&&!_saved; [_root addSubview:_symbols];
  [self label:@"Save in" frame:NSMakeRect(24,390,70,24) size:13 weight:NSFontWeightSemibold color:RailInk()];
  _vaultPicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(100,386,436,30) pullsDown:NO]; _vaultPicker.font=[NSFont systemFontOfSize:13];
  for (NSDictionary *vault in _vaults) { [_vaultPicker addItemWithTitle:vault[@"title"]]; _vaultPicker.lastItem.representedObject=vault[@"id"]; }
  for (NSMenuItem *item in _vaultPicker.itemArray) if ([item.representedObject isEqual:_draftVault]) [_vaultPicker selectItem:item];
  _lengthControl.enabled=_symbols.enabled=!_busy&&!_saved&&!_uncertain;
  _vaultPicker.enabled=!_busy&&!_saved&&!_uncertain; _vaultPicker.accessibilityLabel=@"Destination vault"; [_root addSubview:_vaultPicker];
  RailButton *save=[self button:_saved ? @"Saved to 1Password" : (_uncertain ? @"Retry save…" : @"Save only") frame:NSMakeRect(24,440,170,38) primary:NO action:^{ PasswordPalette *s=weak; if (s->_uncertain) [s confirmRetry]; else [s saveAndFill:NO]; }]; save.enabled=!_busy&&!_saved&&_vaults.count;
  RailButton *fill=[self button:_saved ? @"Fill saved login" : @"Save & fill" frame:NSMakeRect(206,440,330,38) primary:YES action:^{ [weak saveAndFill:YES]; }]; fill.enabled=!_busy&&!_uncertain&&_canFill&&_vaults.count;
  fill.keyEquivalent=@"\r"; fill.keyEquivalentModifierMask=NSEventModifierFlagCommand; fill.toolTip=@"Save & fill (⌘ Return)";
  [_panel makeFirstResponder:_username];
}
- (void)setBusy:(BOOL)busy message:(NSString *)message { [self captureDraft]; _busy=busy; _message=message; [self render]; }
- (NSString *)messageForError:(NSString *)code {
  if ([code isEqual:@"unsafe_page"]) return @"Open an HTTPS page to fill or save a login.";
  if ([code isEqual:@"site_mismatch"]) return @"This login no longer matches this site. Reopen the palette to refresh.";
  if ([code isEqual:@"helper_unavailable"]) return @"The 1Password helper is missing. Rebuild Rail and try again.";
  if ([code isEqual:@"connection_failed"] || [code isEqual:@"not_connected"] || [code isEqual:@"access_failed"]) return @"Open and unlock 1Password, enable app integrations, and check the account name. Then reconnect.";
  if ([code isEqual:@"invalid_login"]) return @"Enter a login name and password, then choose a vault.";
  if ([code isEqual:@"generation_failed"]) return @"Couldn’t generate a password. Try again or enter your own.";
  return @"1Password didn’t finish the request. Reconnect and try again.";
}
- (void)connect {
  if (_busy) return;
  NSString *account=[_account.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!account.length) { _message=@"Enter the account name shown in 1Password."; _status.stringValue=_message; return; }
  [self setBusy:YES message:@"Approve Rail in the 1Password app…"];
  __weak PasswordPalette *weak=self;
  [_service request:@{@"command":@"connect",@"account":account} completion:^(NSDictionary *r) {
    PasswordPalette *s=weak; if (!s||s->_closed) return;
    s->_busy=NO;
    if (r[@"error"]) { s->_message=[s messageForError:r[@"error"]]; [s render]; return; }
    if (!s->_service.fixtureOrigin.length) [NSUserDefaults.standardUserDefaults setObject:account forKey:@"OnePasswordAccount"];
    s->_vaults=r[@"vaults"] ?: @[]; [s loadLogins];
  }];
}
- (void)loadLogins {
  if (_closed || _newLogin || _busy) return;
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(loadLogins) object:nil];
  _searchPending=NO; _loadingLogins=YES;
  NSString *query=[_query copy]; NSInteger offset=_offset; BOOL refresh=_forceRefresh; _forceRefresh=NO;
  [self setBusy:YES message:@"Searching your 1Password items…"];
  __weak PasswordPalette *weak=self;
  [_service request:@{@"command":@"list",@"url":_url,@"query":query,@"offset":@(offset),@"refresh":@(refresh)} completion:^(NSDictionary *r) {
    PasswordPalette *s=weak; if (!s||s->_closed) return; s->_busy=NO; s->_loadingLogins=NO;
    if (!r[@"error"] && (![query isEqual:s->_query] || offset!=s->_offset)) { [s loadLogins]; return; }
    [NSObject cancelPreviousPerformRequestsWithTarget:s selector:@selector(loadLogins) object:nil]; s->_searchPending=NO;
    if (r[@"error"]) { s->_items=@[]; s->_total=0; s->_message=[s messageForError:r[@"error"]]; }
    else { s->_items=r[@"items"] ?: @[]; s->_vaults=r[@"vaults"] ?: @[]; s->_total=[r[@"total"] integerValue]; s->_offset=[r[@"offset"] integerValue]; s->_selected=0; s->_message=@"↑ ↓ to choose  ·  Return to fill or open  ·  Esc to close"; }
    [s render];
  }];
}
- (void)refreshLogins { _forceRefresh=YES; _offset=0; [self loadLogins]; }
- (void)disconnect {
  [NSObject cancelPreviousPerformRequestsWithTarget:self]; _searchPending=NO;
  [_service stop]; _items=@[]; _filtered=@[]; _vaults=@[]; _total=0;
  _draftPassword=@""; _password.stringValue=@""; _draftUsername=@""; _draftTitle=@""; _draftVault=nil;
  _saved=NO; _uncertain=NO; _newLogin=NO; _message=nil; [self render];
}
- (void)searchChanged {
  _query=_search.stringValue ?: @""; _offset=0; _searchPending=YES;
  [self updateSelectionAction];
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(loadLogins) object:nil];
  [self performSelector:@selector(loadLogins) withObject:nil afterDelay:0.075];
}
- (void)newLogin {
  if (_busy || _newLogin || _searchPending) return; [self captureDraft]; _newLogin=YES;
  _message=_uncertain ? @"Couldn’t confirm the save. Check 1Password before retrying. Your original draft is preserved." : (_saved ? @"Saved to 1Password. You can fill it when you’re ready." : @"Save first, then fill. You submit the website’s form."); [self render];
  if (!_draftPassword.length) [self generate];
}
- (void)recipeChanged:(id)sender {
  (void)sender; [self captureDraft]; _length=_lengthControl.integerValue; _symbolsEnabled=_symbols.state==NSControlStateValueOn; [self generate];
}
- (void)generate {
  if (_busy||_saved||_uncertain) return; [self setBusy:YES message:@"Generating a password…"];
  __weak PasswordPalette *weak=self;
  [_service request:@{@"command":@"generate",@"length":@(_length),@"symbols":@(_symbolsEnabled)} completion:^(NSDictionary *r) {
    PasswordPalette *s=weak; if (!s||s->_closed) return; s->_busy=NO;
    if (r[@"error"]) s->_message=[s messageForError:r[@"error"]];
    else { s->_draftPassword=r[@"password"]; s->_message=@"Save first, then fill. You submit the website’s form."; }
    [s render];
  }];
}
- (void)fillUsername:(NSString *)username password:(NSString *)password creating:(BOOL)creating {
  if (!_canFill || !_fill) { _message=@"Page changed. Reopen the palette on the page you want to fill."; _busy=NO; [self render]; return; }
  [self setBusy:YES message:creating ? @"Saved. Filling the account form…" : @"Filling login…"];
  __weak PasswordPalette *weak=self;
  _fill(username,password,creating,^(NSString *status) {
    PasswordPalette *s=weak; if (!s||s->_closed) return; s->_busy=NO;
    if ([status isEqual:@"filled"] || [status isEqual:@"username_filled"]) {
      s->_message=creating ? @"Saved and filled. Complete signup on the website." : ([status isEqual:@"username_filled"] ? @"Username filled. Continue on the website." : @"Login filled. Continue on the website.");
      [s announce:s->_message]; [s close]; return;
    } else {
      s->_message=s->_saved ? @"Saved to 1Password. Couldn’t fill this form; focus its username field and try Fill saved login." : @"Couldn’t fill safely. Focus the login’s username field, then reopen the palette.";
      if ([status isEqual:@"stale_page"]) { s->_canFill=NO; s->_message=s->_saved ? @"Saved to 1Password. The page changed, so nothing was filled." : @"Page changed, so nothing was filled. Reopen the palette."; }
    }
    [s render];
  });
}
- (void)fillSelected {
  if (_busy||_searchPending||_panel.attachedSheet||_selected<0||_selected>=(NSInteger)_filtered.count) return;
  NSDictionary *item=_filtered[_selected];
  if (![item[@"category"] isEqual:@"Login"] || !_canFill) { [self openSelectedItem]; return; }
  if ([item[@"matchesSite"] boolValue]) { [self readLogin:item allowCrossSite:NO]; return; }
  NSArray *sites=[item[@"websites"] isKindOfClass:NSArray.class] ? item[@"websites"] : @[];
  NSURLComponents *destination=[NSURLComponents componentsWithString:_url]; destination.path=@""; destination.query=nil; destination.fragment=nil; destination.user=nil; destination.password=nil;
  NSAlert *alert=[[NSAlert alloc] init]; _crossSiteConfirmation=alert;
  alert.messageText=[NSString stringWithFormat:@"Fill “%@” on this website?",item[@"title"]];
  alert.informativeText=[NSString stringWithFormat:@"Destination: %@\n\n%@\n\nThis login is not configured to fill here. Only continue if you trust this website.",destination.string ?: _url,sites.count ? [@"Saved websites: " stringByAppendingString:[sites componentsJoinedByString:@", "]] : @"This login has no saved website."];
  [alert addButtonWithTitle:@"Cancel"]; [alert addButtonWithTitle:@"Fill this website"];
  __weak PasswordPalette *weak=self;
  [alert beginSheetModalForWindow:_panel completionHandler:^(NSModalResponse result) {
    PasswordPalette *s=weak; if (!s) return; s->_crossSiteConfirmation=nil;
    if (!s->_closed && s->_canFill && result==NSAlertSecondButtonReturn) [s readLogin:item allowCrossSite:YES];
  }];
}
- (void)readLogin:(NSDictionary *)item allowCrossSite:(BOOL)allow {
  if (_closed||!_canFill||_busy) return;
  [self setBusy:YES message:@"Unlock 1Password if prompted…"];
  __weak PasswordPalette *weak=self;
  [_service request:@{@"command":@"get",@"url":_url,@"vault":item[@"vault"],@"item":item[@"id"],@"allowCrossSite":@(allow)} completion:^(NSDictionary *r) {
    PasswordPalette *s=weak; if (!s||s->_closed) return; s->_busy=NO;
    if (r[@"error"]) { s->_message=[s messageForError:r[@"error"]]; [s render]; return; }
    [s fillUsername:r[@"username"] ?: @"" password:r[@"password"] ?: @"" creating:NO];
  }];
}
- (void)openSelectedItem {
  if (_busy||_searchPending||_selected<0||_selected>=(NSInteger)_filtered.count) return;
  NSDictionary *item=_filtered[_selected];
  NSString *routing=_service.fixtureOrigin.length ? _fixtureAccountLink : [NSUserDefaults.standardUserDefaults dictionaryForKey:@"OnePasswordItemLinkAccounts"][_service.connectedAccount];
  if (routing.length) { [self openItem:item routing:routing]; return; }
  NSAlert *alert=[[NSAlert alloc] init]; _itemLinkSetup=alert;
  alert.messageText=@"Enable opening items in 1Password";
  alert.informativeText=[NSString stringWithFormat:@"In 1Password, right-click “%@” and choose Copy Private Link. Paste that link below. Rail remembers the account’s link settings, so you only do this once per account.",item[@"title"]];
  _itemLinkField=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,400,28)]; _itemLinkField.placeholderString=@"https://start.1password.com/open/i?…"; _itemLinkField.accessibilityLabel=@"Private link to the selected item"; alert.accessoryView=_itemLinkField;
  [alert addButtonWithTitle:@"Open item"]; [alert addButtonWithTitle:@"Cancel"];
  __weak PasswordPalette *weak=self;
  [alert beginSheetModalForWindow:_panel completionHandler:^(NSModalResponse result) {
    PasswordPalette *s=weak; if (!s) return; NSString *value=s->_itemLinkField.stringValue; s->_itemLinkField=nil; s->_itemLinkSetup=nil;
    if (!s->_closed && result==NSAlertFirstButtonReturn) [s openItem:item routing:value];
  }];
  [alert.window makeFirstResponder:_itemLinkField];
}
- (void)openItem:(NSDictionary *)item routing:(NSString *)routing {
  [self setBusy:YES message:@"Opening in 1Password…"]; __weak PasswordPalette *weak=self;
  [_service request:@{@"command":@"item-link",@"url":routing,@"vault":item[@"vault"],@"item":item[@"id"]} completion:^(NSDictionary *r) {
    PasswordPalette *s=weak;if (!s||s->_closed) return;s->_busy=NO;
    if (r[@"error"]) { s->_message=@"Use Copy Private Link on this exact item in 1Password, then try again.";[s render];return; }
    if (s->_service.fixtureOrigin.length) {s->_fixtureAccountLink=r[@"accountLink"];s->_fixtureOpenedURL=r[@"link"];[s close];return;}
    NSURL *url=[NSURL URLWithString:r[@"link"]];
    if (url && [NSWorkspace.sharedWorkspace openURL:url]) {
      NSMutableDictionary *accounts=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"OnePasswordItemLinkAccounts"] mutableCopy] ?: NSMutableDictionary.dictionary;
      accounts[s->_service.connectedAccount]=r[@"accountLink"];[NSUserDefaults.standardUserDefaults setObject:accounts forKey:@"OnePasswordItemLinkAccounts"];[s close];
    } else {s->_message=@"Couldn’t open this item. Open the 1Password app and try again.";[s render];}
  }];
}
- (void)saveAndFill:(BOOL)fill {
  if (_busy||_uncertain) return; [self captureDraft];
  if (_saved) { if (fill) [self fillUsername:_draftUsername password:_draftPassword creating:YES]; return; }
  if (!_draftTitle.length || !_draftPassword.length || !_draftVault.length) { _message=@"Enter a login name and password, then choose a vault."; _status.stringValue=_message; return; }
  _saving=YES; [self setBusy:YES message:@"Saving to 1Password…"];
  __weak PasswordPalette *weak=self;
  [_service request:@{@"command":@"create",@"url":_url,@"vault":_draftVault,@"title":_draftTitle,@"username":_draftUsername ?: @"",@"password":_draftPassword} completion:^(NSDictionary *r) {
    PasswordPalette *s=weak; if (!s||s->_closed) return; s->_busy=NO; s->_saving=NO;
    if (r[@"error"]) {
      s->_uncertain=![r[@"error"] isEqual:@"invalid_login"] && ![r[@"error"] isEqual:@"unsafe_page"] && ![r[@"error"] isEqual:@"not_connected"];
      s->_message=s->_uncertain ? @"Couldn’t confirm the save. Check 1Password before creating another login. Your draft is still here." : [s messageForError:r[@"error"]]; [s render]; return;
    }
    s->_saved=YES;
    if (fill) [s fillUsername:s->_draftUsername password:s->_draftPassword creating:YES];
    else { s->_message=@"Saved to 1Password. You can fill it when you’re ready."; [s render]; }
  }];
}
- (void)openOnePassword { [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"onepassword://"]]; }
- (void)confirmRetry {
  if (_busy||!_uncertain) return;
  NSAlert *alert=[[NSAlert alloc] init]; alert.messageText=@"Save this login again?";
  alert.informativeText=@"First check 1Password for this login. Only save again if it is missing; otherwise you may create a duplicate.";
  [alert addButtonWithTitle:@"Cancel"]; [alert addButtonWithTitle:@"It’s missing — save again"];
  __weak PasswordPalette *weak=self;
  [alert beginSheetModalForWindow:_panel completionHandler:^(NSModalResponse result) {
    PasswordPalette *s=weak; if (s && result==NSAlertSecondButtonReturn) { s->_uncertain=NO; [s saveAndFill:NO]; }
  }];
}
- (void)controlTextDidChange:(NSNotification *)note {
  if (note.object==_search) [self searchChanged];
}
- (BOOL)control:(NSControl *)control textView:(NSTextView *)view doCommandBySelector:(SEL)selector {
  (void)view;
  if (selector==@selector(cancelOperation:)) { [self close]; return YES; }
  if (control==_account && selector==@selector(insertNewline:)) { [self connect]; return YES; }
  if (control!=_search) return NO;
  if (selector==@selector(insertNewline:)) { [self fillSelected]; return YES; }
  if (selector==@selector(moveDown:) || selector==@selector(moveUp:)) {
    _selected=MIN(MAX(0,_selected+(selector==@selector(moveDown:) ? 1 : -1)),(NSInteger)_filtered.count-1); [self highlightSelection]; return YES;
  }
  return NO;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; _panel.delegate=nil; }
- (NSDictionary *)automationState {
  NSMutableDictionary *state=[@{@"visible":@(_panel.isVisible),@"busy":@(_busy||_searchPending),@"saved":@(_saved),@"uncertain":@(_uncertain),@"canFill":@(_canFill),@"mode":_newLogin ? @"new" : @"fill",@"count":@(_filtered.count),@"total":@(_total),@"offset":@(_offset),@"confirming":@(_crossSiteConfirmation!=nil),@"searchEnabled":@(_search.enabled),@"action":_fillButton.title ?: @"",@"message":_message ?: @"",@"windowNumber":@(_panel.windowNumber)} mutableCopy];
  if (_service.fixtureOrigin.length) { state[@"openedURL"]=_fixtureOpenedURL ?: @""; state[@"query"]=_query ?: @""; state[@"linkSetup"]=@(_itemLinkSetup!=nil); }
  return state;
}
- (void)driveFixture:(NSDictionary *)command {
  if (!_service.fixtureOrigin.length) return;
  if ([command[@"account"] isKindOfClass:NSString.class]) _account.stringValue=command[@"account"];
  if ([command[@"username"] isKindOfClass:NSString.class]) _username.stringValue=command[@"username"];
  if ([command[@"title"] isKindOfClass:NSString.class]) _titleField.stringValue=command[@"title"];
  if ([command[@"query"] isKindOfClass:NSString.class]) { _search.stringValue=command[@"query"]; [self searchChanged]; }
  if ([command[@"privateLink"] isKindOfClass:NSString.class]) _itemLinkField.stringValue=command[@"privateLink"];
  if ([command[@"button"] isEqual:@"Escape"]) { [self close]; return; }
  if (_crossSiteConfirmation) { for (NSButton *button in _crossSiteConfirmation.buttons) if ([button.title isEqual:command[@"button"]]) { [button performClick:nil]; return; } }
  if (_itemLinkSetup) { for (NSButton *button in _itemLinkSetup.buttons) if ([button.title isEqual:command[@"button"]]) { [button performClick:nil]; return; } }
  for (NSView *v in _root.subviews) if ([v isKindOfClass:NSButton.class] && [((NSButton *)v).title isEqual:command[@"button"]]) { [(NSButton *)v performClick:nil]; break; }
}
@end
