# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(pyvis_editor LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "pyvis_editor")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd4100)
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# The pinned WebView plugin still uses the experimental coroutine headers
# through WIL. Keep the compatibility flag local to that plugin.
if(MSVC AND TARGET flutter_inappwebview_windows_plugin)
  target_compile_definitions(flutter_inappwebview_windows_plugin PRIVATE
    _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)
endif()

# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the hook/build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# CPython's official embeddable build uses its ._pth file even with PYTHONPATH set.
include(FetchContent)
if(CMAKE_GENERATOR_PLATFORM MATCHES "^[Aa][Rr][Mm]64$")
  set(PYVIS_PYTHON_ARCH arm64)
  set(PYVIS_PYTHON_SHA f6773983c8959d4281e48c4540cb0bdd23e42391e4e951ce17e7ceb52658f21c)
else()
  set(PYVIS_PYTHON_ARCH amd64)
  set(PYVIS_PYTHON_SHA d297e5ff019966817ad8502465176139f2d3d840fa4ed84b13bed399a6ab1f15)
endif()
FetchContent_Declare(pyvis_cpython
  URL "https://www.python.org/ftp/python/3.14.7/python-3.14.7-embed-${PYVIS_PYTHON_ARCH}.zip"
  URL_HASH "SHA256=${PYVIS_PYTHON_SHA}")
FetchContent_MakeAvailable(pyvis_cpython)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/python314._pth" "python314.zip\n.\n../data/runtime\nimport site\n")
set(INSTALL_BUNDLE_PYTHON_DIR "${CMAKE_INSTALL_PREFIX}/python")
install(DIRECTORY "${pyvis_cpython_SOURCE_DIR}/" DESTINATION "${INSTALL_BUNDLE_PYTHON_DIR}" COMPONENT Runtime
  PATTERN "*._pth" EXCLUDE)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/python314._pth" DESTINATION "${INSTALL_BUNDLE_PYTHON_DIR}" COMPONENT Runtime)
# ty discovers the embedded interpreter through its site-packages directory.
# Keep a file there so both the MSI and portable ZIP retain the directory.
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/site-packages-readme.txt"
  "This directory enables ty to discover the bundled Python environment.\n")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/site-packages-readme.txt"
  DESTINATION "${INSTALL_BUNDLE_PYTHON_DIR}/Lib/site-packages" COMPONENT Runtime)
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../../runtime/pyvis_runtime"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/runtime" COMPONENT Runtime
  PATTERN "__pycache__" EXCLUDE PATTERN ".DS_Store" EXCLUDE
  PATTERN "*-macosx_*.whl" EXCLUDE)
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../../examples/"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/examples" COMPONENT Runtime
  FILES_MATCHING PATTERN "*.py")
