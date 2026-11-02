# Ad-hoc signatures identify a particular binary, so Keychain's Always Allow
# stops matching after a rebuild. Pin a certificate when there is just one;
# keep explicit selections (including '-') and never choose between identities.
if(RAIL_SIGN_IDENTITY STREQUAL "AUTO")
  execute_process(
    COMMAND /usr/bin/security find-identity -v -p codesigning
    RESULT_VARIABLE _identity_result
    OUTPUT_VARIABLE _identity_output
    ERROR_QUIET
  )
  string(REGEX MATCHALL "[0-9A-F]+ \"[^\"]+\"" _identities "${_identity_output}")
  list(LENGTH _identities _identity_count)
  if(_identity_result EQUAL 0 AND _identity_count EQUAL 1)
    list(GET _identities 0 _identity)
    string(REGEX MATCH "^[0-9A-F]+" _identity_hash "${_identity}")
    set(RAIL_SIGN_IDENTITY "${_identity_hash}" CACHE STRING
      "Local macOS signing identity; AUTO selects a single installed identity, '-' uses ad-hoc signing" FORCE)
    message(STATUS "Selected and cached signing identity: ${_identity}")
  else()
    # Leave AUTO in the cache, so installing/selecting a certificate later works.
    set(RAIL_SIGN_IDENTITY "-")
    message(WARNING
      "No unique code-signing identity found; using ad-hoc signing. "
      "macOS Keychain approvals may repeat after rebuilding. "
      "Run security find-identity -v -p codesigning, then configure "
      "-DRAIL_SIGN_IDENTITY=<identity> to keep approvals across builds.")
  endif()
endif()
message(STATUS "Local signing identity: ${RAIL_SIGN_IDENTITY}")
