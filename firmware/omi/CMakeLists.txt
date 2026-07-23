cmake_minimum_required(VERSION 3.20.0)

set(OMI_VERSION_MAJOR 0)
set(OMI_VERSION_MINOR 0)
set(OMI_VERSION_PATCHLEVEL 0)
set(OMI_VERSION_EXTRA "")

file(STRINGS ${CMAKE_CURRENT_SOURCE_DIR}/VERSION omi_version_lines)
foreach(omi_version_line ${omi_version_lines})
    if(omi_version_line MATCHES "^[ \t]*VERSION_MAJOR[ \t]*=[ \t]*([0-9]+)")
        set(OMI_VERSION_MAJOR ${CMAKE_MATCH_1})
    elseif(omi_version_line MATCHES "^[ \t]*VERSION_MINOR[ \t]*=[ \t]*([0-9]+)")
        set(OMI_VERSION_MINOR ${CMAKE_MATCH_1})
    elseif(omi_version_line MATCHES "^[ \t]*PATCHLEVEL[ \t]*=[ \t]*([0-9]+)")
        set(OMI_VERSION_PATCHLEVEL ${CMAKE_MATCH_1})
    elseif(omi_version_line MATCHES "^[ \t]*EXTRAVERSION[ \t]*=[ \t]*([A-Za-z0-9_.-]+)")
        set(OMI_VERSION_EXTRA ${CMAKE_MATCH_1})
    endif()
endforeach()

set(OMI_FW_REV_STR "${OMI_VERSION_MAJOR}.${OMI_VERSION_MINOR}.${OMI_VERSION_PATCHLEVEL}")
if(NOT OMI_VERSION_EXTRA STREQUAL "")
    string(APPEND OMI_FW_REV_STR "-${OMI_VERSION_EXTRA}")
endif()

set(OMI_GENERATED_VERSION_CONF ${CMAKE_CURRENT_BINARY_DIR}/omi_fw_rev.conf)
file(WRITE ${OMI_GENERATED_VERSION_CONF} "CONFIG_BT_DIS_FW_REV_STR=\"${OMI_FW_REV_STR}\"\n")
list(APPEND EXTRA_CONF_FILE ${OMI_GENERATED_VERSION_CONF})
message(STATUS "Omi firmware revision (DIS 0x2A26): ${OMI_FW_REV_STR}")

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
enable_language(C ASM) # OPUS

project(omi)

file(GLOB app_sources
    src/main.c
    src/mic.c
    src/battery.c
    src/led.c
    src/haptic.c
    src/sd_card.c
    src/spi_flash.c
    src/settings.c
    src/feedback.c
    src/wdog_facade.c
    src/rtc.c
    src/imu.c
)

if(CONFIG_OMI_ENABLE_T5838_AAD)
    # Hardware AAD is integrated into mic.c; t5838_aad.c is the low-level driver.
    list(APPEND app_sources src/t5838_aad.c)
endif()
file(GLOB core_sources
    src/lib/core/config.h
    src/lib/core/codec.c
    src/lib/core/transport.c
    src/lib/core/button.c
    src/lib/core/monitor.c
)

if(CONFIG_OMI_ENABLE_OFFLINE_STORAGE)
    list(APPEND core_sources src/lib/core/storage.c)
endif()

target_sources(app PRIVATE ${core_sources} ${app_sources})
target_include_directories(app PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/lib/core
)

if(CONFIG_OMI_CODEC_OPUS)
    add_subdirectory(src/lib/core/lib/opus-1.2.1/)
    target_link_libraries(app PRIVATE opus_codec)
endif()
