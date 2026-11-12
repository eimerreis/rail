#pragma once

#import <Foundation/Foundation.h>
#include <string>

namespace rail {

// Shared by address-bar suggestions and navigation, including blank tabs and Space home.
// isSearch describes the input, not the resulting host: an explicit engine URL is still a URL.
NSString *NormalizedAddress(NSString *input, const std::string &engineID, BOOL *isSearch = nullptr);

} // namespace rail
