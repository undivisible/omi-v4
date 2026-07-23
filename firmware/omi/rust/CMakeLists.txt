# Links the omi-rust staticlib into the existing C application. This is
# deliberately NOT `rust_cargo_application()` from zephyr-lang-rust: that helper
# adds the module's own main.c and takes over `main()`, which would replace
# firmware/omi/src/main.c. Everything else below mirrors it.

if(NOT COMMAND add_cargo_target_with_zephyr_env)
    message(FATAL_ERROR
        "CONFIG_OMI_RUST=y but the zephyr-lang-rust module is not in the build. "
        "Add it to the west workspace with firmware/west-rust.yml, or pass "
        "-DEXTRA_ZEPHYR_MODULES=<path to zephyr-lang-rust>. See firmware/README.md.")
endif()

get_include_dirs(zephyr_interface include_dirs)
get_property(include_defines TARGET zephyr_interface PROPERTY INTERFACE_COMPILE_DEFINITIONS)

_rust_map_target()
message(STATUS "omi-rust: building for Rust target ${RUST_TARGET}")

if(CONFIG_DEBUG)
    set(RUST_BUILD_TYPE "debug")
    set(rust_build_type_arg "")
else()
    set(RUST_BUILD_TYPE "release")
    set(rust_build_type_arg "--release")
endif()

set(CARGO_TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/rust/target")
set(RUST_LIBRARY "${CARGO_TARGET_DIR}/${RUST_TARGET}/${RUST_BUILD_TYPE}/libomi_rust.a")
set(DUMMY_FILE "${CMAKE_CURRENT_BINARY_DIR}/always-run-cargo-omi.dummy")

set(command_paths)
foreach(module IN ITEMS zephyr zephyr-build zephyr-sys)
    list(APPEND command_paths
        "--config"
        "patch.crates-io.${module}.path=\\\"$CACHE{RUST_MODULE_DIR}/${module}\\\"")
endforeach()

add_cargo_target_with_zephyr_env(libomirust
    ALL
    OUTPUT ${DUMMY_FILE}
    BYPRODUCTS ${RUST_LIBRARY}
    CARGO_ARGS build
    COMMENT "Building the omi-rust staticlib"
)

if(CONFIG_OMI_RUST_CLIPPY)
    add_cargo_target_with_zephyr_env(omirust_clippy
        ALL
        OUTPUT run_omi_rust_clippy
        CARGO_ARGS clippy -- -D warnings -D clippy::undocumented_unsafe_blocks
        COMMENT "Linting the omi-rust staticlib"
    )
endif()

target_link_libraries(app PUBLIC
    $<TARGET_PROPERTY:linker,rt_library>
    -Wl,--allow-multiple-definition
    ${RUST_LIBRARY})
add_dependencies(app libomirust)

target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
