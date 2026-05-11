cmake_minimum_required(VERSION 3.20)
project(nppAutoDetectIndent LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

set(NPP_MACOS_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_WIN_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus")
set(SCINTILLA_INCLUDE "${NPP_WIN_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

add_library(nppAutoDetectIndent SHARED
    src/nppAutoDetectIndent.mm
)

target_link_libraries(nppAutoDetectIndent PRIVATE
    "-framework Cocoa"
)

target_include_directories(nppAutoDetectIndent PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE}
)

set_target_properties(nppAutoDetectIndent PROPERTIES
    PREFIX ""
    SUFFIX ".dylib"
    OUTPUT_NAME "nppAutoDetectIndent"
)

set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.nextpad++/plugins/nppAutoDetectIndent")
install(TARGETS nppAutoDetectIndent DESTINATION "${PLUGIN_INSTALL_DIR}")
