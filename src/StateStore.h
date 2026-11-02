#import <Foundation/Foundation.h>
#include "BrowserModel.h"
#include "History.h"
#include "Projects.h"
#include "Reading.h"

namespace rail {
bool LoadState(NSString *directory, BrowserModel &model, NSError **error);
bool SaveState(NSString *directory, const BrowserModel &model, NSError **error);
bool LoadHistory(NSString *directory, History &history);
bool SaveHistory(NSString *directory, const History &history, NSError **error);
// projects.json: hand-entered data, so a file that can't be read is reported, never silently replaced.
bool LoadProjects(NSString *directory, Projects &projects, NSError **error);
bool SaveProjects(NSString *directory, const Projects &projects, NSError **error);
// reading.json: saved links can't be recreated either, so it is treated like projects.json.
bool LoadReading(NSString *directory, ReadingList &reading, NSError **error);
bool SaveReading(NSString *directory, const ReadingList &reading, NSError **error);
}
