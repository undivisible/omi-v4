if("${SB_CONFIG_NET_CORE_BOARD}" STREQUAL "")
    message(FATAL_ERROR "No simulated nRF5340 network core selected")
endif()

ExternalZephyrProject_Add(
    APPLICATION hci_ipc
    SOURCE_DIR ${ZEPHYR_BASE}/samples/bluetooth/hci_ipc
    BOARD ${SB_CONFIG_NET_CORE_BOARD}
)

# BT_CTLR is promptless from Zephyr 4.x on and is selected by the link-layer
# choice, so assigning it is both redundant and fatal under Kconfig's
# warn-on-undefined. Upstream targets NCS v2.9.0; this tree is on v3.4.0.
set_config_bool(hci_ipc CONFIG_BT_LL_SOFTDEVICE n)
set_config_bool(hci_ipc CONFIG_BT_LL_SW_SPLIT y)

native_simulator_set_child_images(${DEFAULT_IMAGE} hci_ipc)
native_simulator_set_final_executable(${DEFAULT_IMAGE})
