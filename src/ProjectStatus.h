#import <Foundation/Foundation.h>
#include "Projects.h"
#include "include/cef_request_context.h"

// A repository offered for import.
@interface ProjectRepository : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSString *url;
@end

// Fetches live status for project cards. Everything runs and calls back on the main thread.
// Health checks never carry cookies. Azure DevOps requests run in a session's request
// context and carry its login; they are limited to GET requests to Azure DevOps _apis paths.
// GitHub requests use the device-flow token stored in the Keychain.
@interface ProjectStatusService : NSObject
@property(nonatomic, copy) void (^onChange)(void);
@property(nonatomic, readonly) NSString *gitHubClientID;
- (instancetype)initWithContexts:(CefRefPtr<CefRequestContext> (^)(NSString *sessionID))contexts;
- (const rail::StatusSnapshot &)snapshot;
// Checks what is due: the health of health's environments, and the providers behind sources. A source
// is due sooner while something of the user's is running. Force checks everything now.
- (void)checkHealth:(const std::vector<rail::Project> &)health sources:(const std::vector<rail::Project> &)sources connections:(const std::vector<rail::Connection> &)connections force:(BOOL)force;
// A check the user asked for is still under way. Routine checks show no progress.
- (BOOL)isChecking;
- (BOOL)hasGitHubToken:(NSString *)connectionID;
- (void)signInToGitHub:(NSString *)connectionID
                  code:(void (^)(NSString *userCode, NSString *verificationURL))code
                  done:(void (^)(NSString *login, NSString *error))done;
- (void)cancelGitHubSignIn;
- (void)forgetConnection:(NSString *)connectionID;
- (void)azureRepositories:(NSString *)organization session:(NSString *)sessionID
               completion:(void (^)(NSArray<ProjectRepository *> *repositories, NSString *error, BOOL signedOut))completion;
- (void)gitHubRepositories:(NSString *)connectionID
                completion:(void (^)(NSArray<ProjectRepository *> *repositories, NSString *error, BOOL signedOut))completion;
@end
