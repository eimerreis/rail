#import <Foundation/Foundation.h>
#include "BrowserModel.h"
#include "History.h"

namespace rail {
bool LoadState(NSString *directory, BrowserModel &model, NSError **error);
bool SaveState(NSString *directory, const BrowserModel &model, NSError **error);
bool LoadHistory(NSString *directory, History &history);
bool SaveHistory(NSString *directory, const History &history, NSError **error);
}
