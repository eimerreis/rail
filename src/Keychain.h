#import <Foundation/Foundation.h>

// Generic passwords under the "Rail Connections" service, one per connection ID.
NSData *KeychainRead(NSString *account);
BOOL KeychainWrite(NSString *account, NSData *secret);
void KeychainDelete(NSString *account);

// Renames generic passwords in place, so their secrets and access settings stay. A nil account
// matches and keeps every account. Items already stored under the new name are replaced.
void KeychainRenameItems(NSString *service, NSString *account, NSString *newService, NSString *newAccount, NSString *newLabel);
