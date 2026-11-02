cmake_minimum_required(VERSION 3.21)
project(Eimerrail VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)
option(EIMERRAIL_BUILD_APP "Build the native macOS browser and CEF helpers" ON)
set(EIMERRAIL_SIGN_IDENTITY "AUTO" CACHE STRING "Local macOS signing identity; AUTO selects a single installed identity, '-' uses ad-hoc signing")
# Client ID of the Eimerrail GitHub App (device flow enabled). Can also be set later with
# `defaults write de.eimerreis.eimerrail GitHubClientID <id>`.
set(EIMERRAIL_GITHUB_CLIENT_ID "" CACHE STRING "Client ID of the Eimerrail GitHub App")

add_library(BrowserModel STATIC src/BrowserModel.cpp src/History.cpp src/Projects.cpp src/Reading.cpp)
target_include_directories(BrowserModel PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src")
if(BUILD_TESTING)
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
if(NOT EIMERRAIL_BUILD_APP)
  return()
endif()
if(NOT APPLE)
  message(FATAL_ERROR "The Eimerrail app currently supports Apple Silicon macOS only.")
endif()

include(cmake/Signing.cmake)
# Preserve the effective local identity when the in-app updater builds main.
set(EIMERRAIL_SIGN_IDENTITY_XML "${EIMERRAIL_SIGN_IDENTITY}")
string(REPLACE "&" "&amp;" EIMERRAIL_SIGN_IDENTITY_XML "${EIMERRAIL_SIGN_IDENTITY_XML}")
string(REPLACE "<" "&lt;" EIMERRAIL_SIGN_IDENTITY_XML "${EIMERRAIL_SIGN_IDENTITY_XML}")
string(REPLACE ">" "&gt;" EIMERRAIL_SIGN_IDENTITY_XML "${EIMERRAIL_SIGN_IDENTITY_XML}")

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
  message(FATAL_ERROR "Eimerrail requires the Chromium sandbox. USE_SANDBOX must be ON.")
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

add_executable(Eimerrail MACOSX_BUNDLE
  src/main.mm
  src/AppUpdater.mm
  src/BrowserController.mm
  src/CEFBridge.mm
  src/NativeViews.mm
  src/StateStore.mm
  src/ProjectStatus.mm
  src/ProjectsView.mm
  src/Keychain.mm
  src/FeedParser.mm
  src/ReadingExtractor.mm
  src/ReadingView.mm
  src/ReadingController.mm
)
SET_EXECUTABLE_TARGET_PROPERTIES(Eimerrail)
target_include_directories(Eimerrail PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_compile_options(Eimerrail PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJCXX>:${CEF_COMPILER_FLAGS};${CEF_CXX_COMPILER_FLAGS};-fobjc-arc>"
)
target_link_libraries(Eimerrail PRIVATE BrowserModel libcef_dll_wrapper ${CEF_STANDARD_LIBS} "-framework Network" "-framework Security")
set_target_properties(Eimerrail PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME Eimerrail
  MACOSX_BUNDLE_GUI_IDENTIFIER de.eimerreis.eimerrail
  MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"
)

set(CEF_APP "${CEF_TARGET_OUT_DIR}/Eimerrail.app")
# Bundle the worker before signing; it is copied outside the bundle when run.
set_property(TARGET Eimerrail APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/scripts/reinstall-main.sh")
# The pinned minimal distribution intentionally contains only the Release engine.
# Debug builds of our code can still load that exact engine.
# CEF's copy macro uses ln -sf on directory symlinks. Reusing the destination
# creates nested broken links on a second build, so replace this generated copy.
add_custom_command(TARGET Eimerrail PRE_LINK
  COMMAND "${CMAKE_COMMAND}" -E rm -rf "${CEF_APP}/Contents/Frameworks/Chromium Embedded Framework.framework"
  VERBATIM
)
COPY_MAC_FRAMEWORK(Eimerrail "${CEF_BINARY_DIR_RELEASE}" "${CEF_APP}")

foreach(_suffix_list IN LISTS CEF_HELPER_APP_SUFFIXES)
  string(REPLACE ":" ";" _suffix_list "${_suffix_list}")
  list(GET _suffix_list 0 _name_suffix)
  list(GET _suffix_list 1 _target_suffix)
  list(GET _suffix_list 2 _plist_suffix)
  set(_helper_target "Eimerrail_Helper${_target_suffix}")
  set(HELPER_NAME "Eimerrail Helper${_name_suffix}")
  set(HELPER_BUNDLE_ID "de.eimerreis.eimerrail.helper${_plist_suffix}")
  set(_helper_plist "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist")
  configure_file("${CMAKE_CURRENT_BINARY_DIR}/helper-Info.plist.in" "${_helper_plist}" @ONLY)

  add_executable(${_helper_target} MACOSX_BUNDLE src/helper_mac.cc)
  SET_EXECUTABLE_TARGET_PROPERTIES(${_helper_target})
  target_link_libraries(${_helper_target} PRIVATE libcef_dll_wrapper ${CEF_STANDARD_LIBS})
  set_target_properties(${_helper_target} PROPERTIES
    OUTPUT_NAME "${HELPER_NAME}"
    MACOSX_BUNDLE_INFO_PLIST "${_helper_plist}"
    XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"
  )
  add_dependencies(Eimerrail ${_helper_target})
  set_property(TARGET Eimerrail APPEND PROPERTY LINK_DEPENDS "$<TARGET_FILE:${_helper_target}>")
  set_property(TARGET ${_helper_target} APPEND PROPERTY LINK_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/resources/entitlements-helper.plist"
    "${CMAKE_CURRENT_SOURCE_DIR}/resources/helper-Info.plist.in"
    "${CMAKE_CURRENT_BINARY_DIR}/helper-Info.plist.in"
  )
  add_custom_command(TARGET ${_helper_target} POST_BUILD
    COMMAND /usr/bin/codesign --force --sign "${EIMERRAIL_SIGN_IDENTITY}" --timestamp=none --options runtime
      --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/resources/entitlements-helper.plist"
      "$<TARGET_BUNDLE_DIR:${_helper_target}>"
    VERBATIM
  )
  add_custom_command(TARGET Eimerrail POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
      "$<TARGET_BUNDLE_DIR:${_helper_target}>"
      "${CEF_APP}/Contents/Frameworks/${HELPER_NAME}.app"
    VERBATIM
  )
endforeach()

# Sign nested libraries before the framework and app. Signing is local; no
# notarization, timestamp service, or distribution is used.
set(_framework "${CEF_APP}/Contents/Frameworks/Chromium Embedded Framework.framework")
file(GLOB _cef_libraries "${CEF_BINARY_DIR_RELEASE}/Chromium Embedded Framework.framework/Libraries/*.dylib")
foreach(_library IN LISTS _cef_libraries)
  get_filename_component(_library_name "${_library}" NAME)
  add_custom_command(TARGET Eimerrail POST_BUILD
    COMMAND /usr/bin/codesign --force --sign "${EIMERRAIL_SIGN_IDENTITY}" --timestamp=none
      "${_framework}/Versions/A/Libraries/${_library_name}"
    VERBATIM
  )
endforeach()
set_property(TARGET Eimerrail APPEND PROPERTY LINK_DEPENDS
  "${CEF_BINARY_DIR_RELEASE}/Chromium Embedded Framework.framework/Chromium Embedded Framework"
  "${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist.in"
  "${CMAKE_CURRENT_BINARY_DIR}/Info.plist.in"
  "${CMAKE_CURRENT_SOURCE_DIR}/resources/entitlements.plist"
  "${CMAKE_CURRENT_SOURCE_DIR}/resources/AppIcon.icns"
)
add_custom_command(TARGET Eimerrail POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CEF_APP}/Contents/Resources"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/scripts/reinstall-main.sh" "${CEF_APP}/Contents/Resources/reinstall-main.sh"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/resources/AppIcon.icns" "${CEF_APP}/Contents/Resources/AppIcon.icns"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CEF_ROOT}/LICENSE.txt" "${CEF_APP}/Contents/Resources/CEF-LICENSE.txt"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CEF_ROOT}/CREDITS.html" "${CEF_APP}/Contents/Resources/CEF-CREDITS.html"
  COMMAND /usr/bin/codesign --force --sign "${EIMERRAIL_SIGN_IDENTITY}" --timestamp=none "${_framework}"
  COMMAND /usr/bin/codesign --force --sign "${EIMERRAIL_SIGN_IDENTITY}" --timestamp=none --options runtime
    --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/resources/entitlements.plist" "${CEF_APP}"
  COMMAND /usr/bin/codesign --verify --deep --strict "${CEF_APP}"
  VERBATIM
)

message(STATUS "CEF ${CEF_ROOT}; Chromium sandbox enabled; app: ${CEF_APP}")
