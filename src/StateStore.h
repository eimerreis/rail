#import <Foundation/Foundation.h>
#include "BrowserModel.h"

namespace rail {
bool LoadState(NSString *directory, BrowserModel &model, NSError **error);
bool SaveState(NSString *directory, const BrowserModel &model, NSError **error);
}
