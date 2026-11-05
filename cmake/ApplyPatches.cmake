# Applies patches to a fetched source tree (FetchContent's PATCH_COMMAND, run in that tree):
#   cmake -DGIT=<git> -DPATCHES=<patch;...> -P ApplyPatches.cmake
# The patch step runs again when the fetch details change, a patch file's content included. When
# every patch is already in the tree there is nothing to do; otherwise the tree goes back to the
# fetched commit (a changed patch's earlier version undone) and all of them are applied afresh.
# --ignore-whitespace: Git for Windows checks the tree out with CRLF line ends.
set(all_applied TRUE)
foreach(patch IN LISTS PATCHES)
  execute_process(COMMAND "${GIT}" apply --reverse --check --ignore-whitespace "${patch}"
                  RESULT_VARIABLE not_applied OUTPUT_QUIET ERROR_QUIET)
  if(not_applied)
    set(all_applied FALSE)
  endif()
endforeach()
if(all_applied)
  return()
endif()
execute_process(COMMAND "${GIT}" checkout -- . RESULT_VARIABLE failed)
if(NOT failed)
  execute_process(COMMAND "${GIT}" clean -fdq RESULT_VARIABLE failed)
endif()
if(failed)
  message(FATAL_ERROR "Could not restore the fetched tree before patching")
endif()
foreach(patch IN LISTS PATCHES)
  execute_process(COMMAND "${GIT}" apply --ignore-whitespace "${patch}" RESULT_VARIABLE failed)
  if(failed)
    message(FATAL_ERROR "Could not apply ${patch}")
  endif()
  message(STATUS "Applied ${patch}")
endforeach()
