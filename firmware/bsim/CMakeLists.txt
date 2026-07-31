cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(omi_bsim)

set(OMI_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../omi/src)
set(OMI_RUST_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../omi/rust)

target_sources(app PRIVATE
    src/main.c
    src/stubs.c
    ${OMI_SOURCE_DIR}/settings.c
    ${OMI_SOURCE_DIR}/lib/core/button_service.c
    ${OMI_SOURCE_DIR}/lib/core/transport.c
)

target_include_directories(app PRIVATE
    ${OMI_SOURCE_DIR}
    ${OMI_RUST_DIR}
)

find_program(OMI_BSIM_CARGO cargo)
if(NOT OMI_BSIM_CARGO)
    message(FATAL_ERROR
        "cargo was not found on PATH. firmware/omi/src/lib/core/transport.c calls "
        "into the omi-rust staticlib and has no C-only fallback, so the BabbleSim "
        "harness has to build firmware/omi/rust for the host. Install rustup (see "
        ".github/workflows/ci-firmware.yml) and re-run.")
endif()

if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    if(CONFIG_64BIT)
        set(OMI_BSIM_RUST_TARGET "aarch64-unknown-linux-gnu")
    else()
        set(OMI_BSIM_RUST_TARGET "armv7-unknown-linux-gnueabihf")
    endif()
else()
    if(CONFIG_64BIT)
        set(OMI_BSIM_RUST_TARGET "x86_64-unknown-linux-gnu")
    else()
        set(OMI_BSIM_RUST_TARGET "i686-unknown-linux-gnu")
    endif()
endif()

file(GLOB OMI_RUST_SOURCES ${OMI_RUST_DIR}/src/*.rs)
set(OMI_BSIM_CARGO_TARGET_DIR ${CMAKE_CURRENT_BINARY_DIR}/omi-rust-host)
set(OMI_BSIM_RUST_SRC_DIR ${CMAKE_CURRENT_BINARY_DIR}/omi-rust-src)
set(OMI_BSIM_RUST_LIBRARY
    ${OMI_BSIM_CARGO_TARGET_DIR}/${OMI_BSIM_RUST_TARGET}/release/libomi_rust.a)

add_custom_command(
    OUTPUT ${OMI_BSIM_RUST_LIBRARY}
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${OMI_BSIM_RUST_SRC_DIR}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${OMI_BSIM_RUST_SRC_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy ${OMI_RUST_DIR}/Cargo.toml ${OMI_BSIM_RUST_SRC_DIR}/Cargo.toml
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${OMI_RUST_DIR}/src ${OMI_BSIM_RUST_SRC_DIR}/src
    COMMAND ${CMAKE_COMMAND} -E env
        CARGO_TARGET_DIR=${OMI_BSIM_CARGO_TARGET_DIR}
        ${OMI_BSIM_CARGO} build --release
        --manifest-path ${OMI_BSIM_RUST_SRC_DIR}/Cargo.toml
        --target ${OMI_BSIM_RUST_TARGET}
    DEPENDS ${OMI_RUST_SOURCES} ${OMI_RUST_DIR}/Cargo.toml
    COMMENT "Building the omi-rust staticlib for the BabbleSim host target"
    VERBATIM
)

add_custom_target(omi_bsim_rust DEPENDS ${OMI_BSIM_RUST_LIBRARY})
add_dependencies(app omi_bsim_rust)
target_link_libraries(app PUBLIC
    -Wl,--allow-multiple-definition
    ${OMI_BSIM_RUST_LIBRARY})
