set(SPARKLE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/vendor/sparkle" CACHE PATH "Pinned Sparkle distribution")
if(NOT EXISTS "${SPARKLE_ROOT}/Sparkle.framework/Sparkle")
  message(FATAL_ERROR "Sparkle is missing. Run scripts/bootstrap.sh first.")
endif()
add_library(Sparkle SHARED IMPORTED)
set_target_properties(Sparkle PROPERTIES
  IMPORTED_LOCATION "${SPARKLE_ROOT}/Sparkle.framework/Sparkle"
  FRAMEWORK TRUE
)

# Keep framework symlinks and re-sign each nested executable before its container.
set(_sparkle "${CEF_APP}/Contents/Frameworks/Sparkle.framework")
add_custom_command(TARGET Rail POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E rm -rf "${_sparkle}"
  COMMAND /usr/bin/ditto "${SPARKLE_ROOT}/Sparkle.framework" "${_sparkle}"
  VERBATIM
)
foreach(_binary IN ITEMS XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app)
  add_custom_command(TARGET Rail POST_BUILD
    COMMAND /usr/bin/codesign --force --sign "${RAIL_SIGN_IDENTITY}" ${RAIL_TIMESTAMP_FLAG}
      --options runtime --preserve-metadata=entitlements "${_sparkle}/Versions/B/${_binary}"
    VERBATIM
  )
endforeach()
add_custom_command(TARGET Rail POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CEF_APP}/Contents/Resources"
  COMMAND /usr/bin/codesign --force --sign "${RAIL_SIGN_IDENTITY}" ${RAIL_TIMESTAMP_FLAG}
    --options runtime "${_sparkle}"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${SPARKLE_ROOT}/LICENSE"
    "${CEF_APP}/Contents/Resources/Sparkle-LICENSE.txt"
  VERBATIM
)
set_property(TARGET Rail APPEND PROPERTY LINK_DEPENDS
  "${SPARKLE_ROOT}/Sparkle.framework/Sparkle"
  "${CMAKE_CURRENT_SOURCE_DIR}/sparkle.lock.json"
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Sparkle.cmake"
)
