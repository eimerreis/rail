#import <Foundation/Foundation.h>

// Generic passwords under the "Eimerrail Connections" service, one per connection ID.
NSData *KeychainRead(NSString *account);
BOOL KeychainWrite(NSString *account, NSData *secret);
void KeychainDelete(NSString *account);
