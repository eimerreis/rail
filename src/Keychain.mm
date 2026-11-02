#import "Keychain.h"
#import <Security/Security.h>

static NSString *const Service = @"Rail Connections";

static NSMutableDictionary *Query(NSString *account) {
  return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:Service,(__bridge id)kSecAttrAccount:account ?: @""} mutableCopy];
}
NSData *KeychainRead(NSString *account) {
  NSMutableDictionary *query = Query(account);
  query[(__bridge id)kSecReturnData] = @YES; query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
  CFTypeRef result = NULL;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return nil;
  return (__bridge_transfer NSData *)result;
}
BOOL KeychainWrite(NSString *account, NSData *secret) {
  NSDictionary *update = @{(__bridge id)kSecValueData:secret};
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)Query(account), (__bridge CFDictionaryRef)update);
  if (status == errSecItemNotFound) {
    NSMutableDictionary *item = Query(account);
    item[(__bridge id)kSecValueData] = secret;
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    item[(__bridge id)kSecAttrLabel] = @"Rail connection";
    status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
  }
  return status == errSecSuccess;
}
void KeychainDelete(NSString *account) { SecItemDelete((__bridge CFDictionaryRef)Query(account)); }
void KeychainRenameItems(NSString *service, NSString *account, NSString *newService, NSString *newAccount, NSString *newLabel) {
  NSMutableDictionary *query = [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:service} mutableCopy];
  if (account) query[(__bridge id)kSecAttrAccount] = account;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL) != errSecSuccess) return;
  NSMutableDictionary *stale = [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:newService} mutableCopy];
  if (newAccount) stale[(__bridge id)kSecAttrAccount] = newAccount;
  SecItemDelete((__bridge CFDictionaryRef)stale);
  NSMutableDictionary *update = [@{(__bridge id)kSecAttrService:newService,(__bridge id)kSecAttrLabel:newLabel} mutableCopy];
  if (newAccount) update[(__bridge id)kSecAttrAccount] = newAccount;
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
  if (status != errSecSuccess) NSLog(@"Rail cannot move keychain items from %@: %d", service, (int)status);
}
