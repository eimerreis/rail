cmake_minimum_required(VERSION 3.21)
project(Rail VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)
option(RAIL_BUILD_APP "Build the native macOS browser and CEF helpers" ON)
set(RAIL_SIGN_IDENTITY "AUTO" CACHE STRING "Local macOS signing identity; AUTO selects a single installed identity, '-' uses ad-hoc signing")
set(RAIL_BUILD_VERSION "${PROJECT_VERSION}" CACHE STRING "Monotonically increasing Sparkle build version")
set(RAIL_UPDATE_FEED_URL "https://github.com/eimerreis/rail/releases/latest/download/appcast.xml" CACHE STRING "HTTPS Sparkle appcast URL")
set(RAIL_UPDATE_PUBLIC_KEY "" CACHE STRING "Base64 Sparkle Ed25519 public key; empty disables release updates")
option(RAIL_DISTRIBUTION "Use timestamped Developer ID signatures for distribution" OFF)
# Client ID of the Rail GitHub App (device flow enabled). Can also be set later with
# `defaults write de.eimerreis.rail GitHubClientID <id>`.
set(RAIL_GITHUB_CLIENT_ID "" CACHE STRING "Client ID of the Rail GitHub App")

add_library(BrowserModel STATIC src/BrowserModel.cpp src/History.cpp src/Projects.cpp src/Reading.cpp)
target_include_directories(BrowserModel PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src")
if(BUILD_TESTING)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  add_test(NAME UpdateTests COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/UpdateTests.py")
  add_executable(BrowserModelTests tests/BrowserModelTests.cpp)
  target_link_libraries(BrowserModelTests PRIVATE BrowserModel)
  add_test(NAME BrowserModelTests COMMAND BrowserModelTests)
  add_executable(HistoryTests tests/HistoryTests.cpp)
  target_link_libraries(HistoryTests PRIVATE BrowserModel)
  add_test(NAME HistoryTests COMMAND HistoryTests)
  add_executable(ProjectsTests tests/ProjectsTests.cpp)
  target_link_libraries(ProjectsTests PRIVATE BrowserModel)
  add_test(NAME ProjectsTests COMMAND ProjectsTests)
  add_executable(ReadingTests tests/ReadingTests.cpp)
  target_link_libraries(ReadingTests PRIVATE BrowserModel)
  add_test(NAME ReadingTests COMMAND ReadingTests)
  if(APPLE AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/StateStoreTests.mm")
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    add_test(NAME ReinstallMainTests COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tests/ReinstallMainTests.py")
    enable_language(OBJCXX)
    add_executable(StateStoreTests tests/StateStoreTests.mm src/StateStore.mm)
    target_compile_options(StateStoreTests PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    target_link_libraries(StateStoreTests PRIVATE BrowserModel "-framework Foundation")
    set_target_properties(StateStoreTests PROPERTIES
      OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED ON OBJCXX_EXTENSIONS OFF
    )
    add_test(NAME StateStoreTests COMMAND StateStoreTests)
    add_executable(FeedParserTests tests/FeedParserTests.mm src/FeedParser.mm src/StateStore.mm)
    target_compile_options(FeedParserTests PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    target_link_libraries(FeedParserTests PRIVATE BrowserModel "-framework Foundation")
    set_target_properties(FeedParserTests PROPERTIES
      OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED ON OBJCXX_EXTENSIONS OFF
    )
    add_test(NAME FeedParserTests COMMAND FeedParserTests)
  endif()
endif()

# Domain tests can be configured without macOS, CEF, or the Objective-C compiler.
if(NOT RAIL_BUILD_APP)
  return()
endif()
if(NOT APPLE)
  message(FATAL_ERROR "The Rail app currently supports Apple Silicon macOS only.")
endif()

include(cmake/Signing.cmake)
set(RAIL_TIMESTAMP_FLAG --timestamp=none)
if(RAIL_DISTRIBUTION)
  if(RAIL_SIGN_IDENTITY STREQUAL "-")
    message(FATAL_ERROR "Distribution requires a Developer ID signing identity.")
  endif()
  if(NOT RAIL_UPDATE_FEED_URL MATCHES "^https://[^/]+/" OR RAIL_UPDATE_PUBLIC_KEY STREQUAL "")
    message(FATAL_ERROR "Distribution requires an HTTPS Sparkle feed and an Ed25519 public key.")
  endif()
  set(RAIL_TIMESTAMP_FLAG --timestamp)
endif()
if(NOT RAIL_BUILD_VERSION MATCHES "^[0-9]+(\\.[0-9]+)*$")
  message(FATAL_ERROR "RAIL_BUILD_VERSION must be a numeric dotted version.")
endif()
if(NOT RAIL_UPDATE_PUBLIC_KEY STREQUAL "")
  string(LENGTH "${RAIL_UPDATE_PUBLIC_KEY}" _update_key_length)
  # A 32-byte Ed25519 public key is 44 base64 characters with one '='.
  if(NOT _update_key_length EQUAL 44 OR NOT RAIL_UPDATE_PUBLIC_KEY MATCHES "^[A-Za-z0-9+/]+=$")
    message(FATAL_ERROR "RAIL_UPDATE_PUBLIC_KEY must be a base64-encoded Ed25519 public key.")
  endif()
endif()
set(RAIL_UPDATE_FEED_URL_XML "${RAIL_UPDATE_FEED_URL}")
string(REPLACE "&" "&amp;" RAIL_UPDATE_FEED_URL_XML "${RAIL_UPDATE_FEED_URL_XML}")
string(REPLACE "<" "&lt;" RAIL_UPDATE_FEED_URL_XML "${RAIL_UPDATE_FEED_URL_XML}")
string(REPLACE ">" "&gt;" RAIL_UPDATE_FEED_URL_XML "${RAIL_UPDATE_FEED_URL_XML}")
# Preserve the effective local identity when the in-app updater builds main.
set(RAIL_SIGN_IDENTITY_XML "${RAIL_SIGN_IDENTITY}")
string(REPLACE "&" "&amp;" RAIL_SIGN_IDENTITY_XML "${RAIL_SIGN_IDENTITY_XML}")
string(REPLACE "<" "&lt;" RAIL_SIGN_IDENTITY_XML "${RAIL_SIGN_IDENTITY_XML}")
string(REPLACE ">" "&gt;" RAIL_SIGN_IDENTITY_XML "${RAIL_SIGN_IDENTITY_XML}")

enable_language(C OBJCXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_EXTENSIONS OFF)
set(PROJECT_ARCH "arm64")
set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/vendor/cef" CACHE PATH "Pinned CEF distribution")
if(NOT EXISTS "${CEF_ROOT}/cmake/FindCEF.cmake")
  message(FATAL_ERROR "CEF is missing. Run scripts/bootstrap.sh first.")
endif()
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
if(NOT USE_SANDBOX)
  message(FATAL_ERROR "Rail requires the Chromium sandbox. USE_SANDBOX must be ON.")
endif()
add_subdirectory("${CEF_LIBCEF_DLL_WRAPPER_PATH}" libcef_dll_wrapper)
SET_CEF_TARGET_OUT_DIR()

# Chromium reserializes cached Info.plist dictionaries for dynamic signature
# checks. Normalize the templates so the signed bytes match that XML exactly.
# Do this before generation to avoid rewriting already-signed bundles on configure.
foreach(_plist IN ITEMS Info.plist.in helper-Info.plist.in)
  configure_file("resources/${_plist}" "${CMAKE_CURRENT_BINARY_DIR}/normalized-${_plist}" COPYONLY)
  execute_process(
    COMMAND /usr/bin/plutil -convert xml1 "${CMAKE_CURRENT_BINARY_DIR}/normalized-${_plist}"
    COMMAND_ERROR_IS_FATAL ANY
  )
  configure_file("${CMAKE_CURRENT_BINARY_DIR}/normalized-${_plist}" "${CMAKE_CURRENT_BINARY_DIR}/${_plist}" COPYONLY)
endforeach()

add_executable(Rail MACOSX_BUNDLE
  src/main.mm
  src/AppUpdater.mm
  src/ReleaseUpdater.mm
  src/BrowserController.mm
  src/CEFBridge.mm
  src/NativeViews.mm
  src/Theme.mm
  src/StateStore.mm
  src/ProjectStatus.mm
  src/ProjectsView.mm
  src/ActivityView.mm
  src/SettingsWindow.mm
  src/Keychain.mm
  src/FeedParser.mm
  src/ReadingExtractor.mm
  src/ReadingView.mm
  src/ReadingController.mm
  src/PasswordService.mm
  src/PasswordPalette.mm
)
SET_EXECUTABLE_TARGET_PROPERTIES(Rail)
target_include_directories(Rail PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_compile_options(Rail PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJCXX>:${CEF_COMPILER_FLAGS};${CEF_CXX_COMPILER_FLAGS};-fobjc-arc>"
)
target_link_libraries(Rail PRIVATE BrowserModel libcef_dll_wrapper ${CEF_STANDARD_LIBS} "-framework Network" "-framework Security" "-framework CoreText" Sparkle)
set_target_properties(Rail PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME Rail
  MACOSX_BUNDLE_GUI_IDENTIFIER de.eimerreis.rail
  MACOSX_BUNDLE_BUNDLE_VERSION "${RAIL_BUILD_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"
  BUILD_WITH_INSTALL_RPATH TRUE
  INSTALL_RPATH "@executable_path/../Frameworks"
)

set(CEF_APP "${CEF_TARGET_OUT_DIR}/Rail.app")
include(cmake/Sparkle.cmake)
# Bundle the worker before signing; it is copied outside the bundle when run.
set_property(TARGET Rail APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/scripts/reinstall-main.sh")
find_program(RAIL_GO go HINTS "${CMAKE_CURRENT_SOURCE_DIR}/.tools/go/bin" REQUIRED)
set(_password_helper "${CMAKE_CURRENT_BINARY_DIR}/RailPasswordHelper")
file(GLOB _password_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/helpers/onepassword/*.go")
add_custom_command(OUTPUT "${_password_helper}"
  COMMAND "${CMAKE_COMMAND}" -E env CGO_ENABLED=1
    "MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}"
    "CGO_CFLAGS=-O2 -g -mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}"
    "CGO_LDFLAGS=-O2 -g -mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}"
    "${RAIL_GO}" build -trimpath -o "${_password_helper}" .
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/helpers/onepassword"
  DEPENDS ${_password_sources} helpers/onepassword/go.mod helpers/onepassword/go.sum
  VERBATIM
)
add_custom_target(RailPasswordHelperBuild DEPENDS "${_password_helper}")
add_dependencies(Rail RailPasswordHelperBuild)
set_property(TARGET Rail APPEND PROPERTY LINK_DEPENDS "${_password_helper}")
if(BUILD_TESTING)
  add_test(NAME PasswordHelperTests COMMAND "${RAIL_GO}" test ./...)
  set_tests_properties(PasswordHelperTests PROPERTIES WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/helpers/onepassword")
endif()
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/src/CredentialForm.js" RAIL_CREDENTIAL_FORM_JS)
configure_file(src/CredentialForm.h.in "${CMAKE_CURRENT_BINARY_DIR}/generated/CredentialForm.h" @ONLY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/CredentialForm.js")
# The pinned minimal distribution intentionally contains only the Release engine.
# Debug builds of our code can still load that exact engine.
# CEF's copy macro uses ln -sf on directory symlinks. Reusing the destination
# creates nested broken links on a second build, so replace this generated copy.
add_custom_command(TARGET Rail PRE_LINK
  COMMAND "${CMAKE_COMMAND}" -E rm -rf "${CEF_APP}/Contents/Frameworks/Chromium Embedded Framework.framework"
  VERBATIM
)
COPY_MAC_FRAMEWORK(Rail "${CEF_BINARY_DIR_RELEASE}" "${CEF_APP}")

foreach(_suffix_list IN LISTS CEF_HELPER_APP_SUFFIXES)
  string(REPLACE ":" ";" _suffix_list "${_suffix_list}")
  list(GET _suffix_list 0 _name_suffix)
  list(GET _suffix_list 1 _target_suffix)
  list(GET _suffix_list 2 _plist_suffix)
  set(_helper_target "Rail_Helper${_target_suffix}")
  set(HELPER_NAME "Rail Helper${_name_suffix}")
  set(HELPER_BUNDLE_ID "de.eimerreis.rail.helper${_plist_suffix}")
  set(_helper_plist "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist")
  configure_file("${CMAKE_CURRENT_BINARY_DIR}/helper-Info.plist.in" "${_helper_plist}" @ONLY)

  add_executable(${_helper_target} MACOSX_BUNDLE src/helper_mac.cc src/CredentialRenderer.cc)
  target_include_directories(${_helper_target} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/generated")
  SET_EXECUTABLE_TARGET_PROPERTIES(${_helper_target})
  target_link_libraries(${_helper_target} PRIVATE libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(${_helper_target} PROPERTIES
    OUTPUT_NAME "${HELPER_NAME}"
    MACOSX_BUNDLE_INFO_PLIST "${_helper_plist}"
    XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"
  )
  add_dependencies(Rail ${_helper_target})
  set_property(TARGET Rail APPEND PROPERTY LINK_DEPENDS "$<TARGET_FILE:${_helper_target}>")
  set_property(TARGET ${_helper_target} APPEND PROPERTY LINK_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/resources/entitlements-helper.plist"
    "${CMAKE_CURRENT_SOURCE_DIR}/resources/helper-Info.plist.in"
    "${CMAKE_CURRENT_BINARY_DIR}/helper-Info.plist.in"
  )
  add_custom_command(TARGET ${_helper_target} POST_BUILD
    COMMAND /usr/bin/codesign --force --sign "${RAIL_SIGN_IDENTITY}" ${RAIL_TIMESTAMP_FLAG} --options runtime
      --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/resources/entitlements-helper.plist"
      "$<TARGET_BUNDLE_DIR:${_helper_target}>"
    VERBATIM
  )
  add_custom_command(TARGET Rail POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
      "$<TARGET_BUNDLE_DIR:${_helper_target}>"
      "${CEF_APP}/Contents/Frameworks/${HELPER_NAME}.app"
    VERBATIM
  )
endforeach()

# Sign nested libraries before the framework and app.
set(_framework "${CEF_APP}/Contents/Frameworks/Chromium Embedded Framework.framework")
file(GLOB _cef_libraries "${CEF_BINARY_DIR_RELEASE}/Chromium Embedded Framework.framework/Libraries/*.dylib")
foreach(_library IN LISTS _cef_libraries)
  get_filename_component(_library_name "${_library}" NAME)
  add_custom_command(TARGET Rail POST_BUILD
    COMMAND /usr/bin/codesign --force --sign "${RAIL_SIGN_IDENTITY}" ${RAIL_TIMESTAMP_FLAG}
      "${_framework}/Versions/A/Libraries/${_library_name}"
    VERBATIM
  )
endforeach()
set_property(TARGET Rail APPEND PROPERTY LINK_DEPENDS
  "${CEF_BINARY_DIR_RELEASE}/Chromium Embedded Framework.framework/Chromium Embedded Framework"
  "${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist.in"
  "${CMAKE_CURRENT_BINARY_DIR}/Info.plist.in"
  "${CMAKE_CURRENT_SOURCE_DIR}/resources/entitlements.plist"
  "${CMAKE_CURRENT_SOURCE_DIR}/resources/AppIcon.icns"
  "${CMAKE_CURRENT_SOURCE_DIR}/resources/RailMark.pdf"
  "${CMAKE_CURRENT_SOURCE_DIR}/resources/fonts/Manrope-Variable.ttf"
  "${CMAKE_CURRENT_SOURCE_DIR}/resources/entitlements-password-helper.plist"
  "${CMAKE_CURRENT_SOURCE_DIR}/resources/OnePassword-Notices.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/cef.lock.json"
)
add_custom_command(TARGET Rail POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_password_helper}" "${CEF_APP}/Contents/MacOS/RailPasswordHelper"
  COMMAND /usr/bin/codesign --force --sign "${RAIL_SIGN_IDENTITY}" ${RAIL_TIMESTAMP_FLAG} --options runtime
    --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/resources/entitlements-password-helper.plist" "${CEF_APP}/Contents/MacOS/RailPasswordHelper"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CEF_APP}/Contents/Resources"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${CMAKE_CURRENT_SOURCE_DIR}/resources/OnePassword-Notices.txt" "${CEF_APP}/Contents/Resources/OnePassword-Notices.txt"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/scripts/reinstall-main.sh" "${CEF_APP}/Contents/Resources/reinstall-main.sh"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/resources/AppIcon.icns" "${CEF_APP}/Contents/Resources/AppIcon.icns"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/resources/RailMark.pdf" "${CEF_APP}/Contents/Resources/RailMark.pdf"
  # Manrope (SIL Open Font License) is registered for this process at launch; no install needed.
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CEF_APP}/Contents/Resources/Fonts"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/resources/fonts/Manrope-Variable.ttf" "${CEF_APP}/Contents/Resources/Fonts/Manrope-Variable.ttf"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/resources/fonts/Manrope-OFL.txt" "${CEF_APP}/Contents/Resources/Fonts/Manrope-OFL.txt"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CEF_ROOT}/LICENSE.txt" "${CEF_APP}/Contents/Resources/CEF-LICENSE.txt"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CEF_ROOT}/CREDITS.html" "${CEF_APP}/Contents/Resources/CEF-CREDITS.html"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/cef.lock.json" "${CEF_APP}/Contents/Resources/cef.lock.json"
  COMMAND /usr/bin/codesign --force --sign "${RAIL_SIGN_IDENTITY}" ${RAIL_TIMESTAMP_FLAG} "${_framework}"
  COMMAND /usr/bin/codesign --force --sign "${RAIL_SIGN_IDENTITY}" ${RAIL_TIMESTAMP_FLAG} --options runtime
    --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/resources/entitlements.plist" "${CEF_APP}"
  COMMAND /usr/bin/codesign --verify --deep --strict "${CEF_APP}"
  VERBATIM
)

message(STATUS "CEF ${CEF_ROOT}; Chromium sandbox enabled; app: ${CEF_APP}")

if(BUILD_TESTING)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  add_test(NAME BundlePrivacyTests COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests/BundlePrivacyTests.py" "${CEF_APP}")
  add_test(NAME BundleCompatibilityTests COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests/BundleCompatibilityTests.py" "${CEF_APP}")
endif()
