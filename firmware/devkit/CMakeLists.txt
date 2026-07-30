# SPDX-License-Identifier: Apache-2.0
set(BOARD seeed_xiao_nrf52840_sense)
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
message(STATUS "Omi DevKit firmware revision (DIS 0x2A26): ${OMI_FW_REV_STR}")

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(nrf52840_nordic)
enable_language(C ASM)

# Opus is vendored once, under the production tree. The devkit built from its
# own byte-identical copy for no reason other than that it was copied.
set(OMI_OPUS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../omi/src/lib/core/lib/opus-1.2.1)
# codec.c includes it as "lib/opus-1.2.1/opus.h", so the parent of `lib/` has
# to be on the include path now that the tree is shared rather than local.
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../omi/src/lib/core)

target_sources(app PRIVATE
    src/main.c
    src/transport.c
    src/mic.c
    src/led.c
    src/codec.c
    src/lib/battery/battery.c
    src/button.c
    src/speaker.c
    src/sdcard.c
    src/storage.c
    src/omi_ext.c
    src/usb.c
    src/wdog_facade.c
	# src/nfc.c future release
)

target_sources_ifdef(CONFIG_OMI_CODEC_OPUS app PRIVATE
    ${OMI_OPUS_DIR}/A2NLSF.c
    ${OMI_OPUS_DIR}/CNG.c
    ${OMI_OPUS_DIR}/HP_variable_cutoff.c
    ${OMI_OPUS_DIR}/LPC_analysis_filter.c
    ${OMI_OPUS_DIR}/LPC_fit.c
    ${OMI_OPUS_DIR}/LPC_inv_pred_gain.c
    ${OMI_OPUS_DIR}/LP_variable_cutoff.c
    ${OMI_OPUS_DIR}/LTP_analysis_filter_FIX.c
    ${OMI_OPUS_DIR}/LTP_scale_ctrl_FIX.c
    ${OMI_OPUS_DIR}/NLSF2A.c
    ${OMI_OPUS_DIR}/NLSF_VQ.c
    ${OMI_OPUS_DIR}/NLSF_VQ_weights_laroia.c
    ${OMI_OPUS_DIR}/NLSF_decode.c
    ${OMI_OPUS_DIR}/NLSF_del_dec_quant.c
    ${OMI_OPUS_DIR}/NLSF_encode.c
    ${OMI_OPUS_DIR}/NLSF_stabilize.c
    ${OMI_OPUS_DIR}/NLSF_unpack.c
    ${OMI_OPUS_DIR}/NSQ.c
    ${OMI_OPUS_DIR}/NSQ_del_dec.c
    ${OMI_OPUS_DIR}/PLC.c
    ${OMI_OPUS_DIR}/VAD.c
    ${OMI_OPUS_DIR}/VQ_WMat_EC.c
    ${OMI_OPUS_DIR}/ana_filt_bank_1.c
    ${OMI_OPUS_DIR}/analysis.c
    ${OMI_OPUS_DIR}/apply_sine_window_FIX.c
    ${OMI_OPUS_DIR}/autocorr_FIX.c
    ${OMI_OPUS_DIR}/bands.c
    ${OMI_OPUS_DIR}/biquad_alt.c
    ${OMI_OPUS_DIR}/burg_modified_FIX.c
    ${OMI_OPUS_DIR}/bwexpander.c
    ${OMI_OPUS_DIR}/bwexpander_32.c
    ${OMI_OPUS_DIR}/celt.c
    ${OMI_OPUS_DIR}/celt_decoder.c
    ${OMI_OPUS_DIR}/celt_encoder.c
    ${OMI_OPUS_DIR}/celt_lpc.c
    ${OMI_OPUS_DIR}/arm/celt_pitch_xcorr_arm_gcc.s
    ${OMI_OPUS_DIR}/check_control_input.c
    ${OMI_OPUS_DIR}/code_signs.c
    ${OMI_OPUS_DIR}/control_SNR.c
    ${OMI_OPUS_DIR}/control_audio_bandwidth.c
    ${OMI_OPUS_DIR}/control_codec.c
    ${OMI_OPUS_DIR}/corrMatrix_FIX.c
    ${OMI_OPUS_DIR}/cwrs.c
    ${OMI_OPUS_DIR}/debug.c
    ${OMI_OPUS_DIR}/dec_API.c
    ${OMI_OPUS_DIR}/decode_core.c
    ${OMI_OPUS_DIR}/decode_frame.c
    ${OMI_OPUS_DIR}/decode_indices.c
    ${OMI_OPUS_DIR}/decode_parameters.c
    ${OMI_OPUS_DIR}/decode_pitch.c
    ${OMI_OPUS_DIR}/decode_pulses.c
    ${OMI_OPUS_DIR}/decoder_set_fs.c
    ${OMI_OPUS_DIR}/enc_API.c
    ${OMI_OPUS_DIR}/encode_frame_FIX.c
    ${OMI_OPUS_DIR}/encode_indices.c
    ${OMI_OPUS_DIR}/encode_pulses.c
    ${OMI_OPUS_DIR}/entcode.c
    ${OMI_OPUS_DIR}/entdec.c
    ${OMI_OPUS_DIR}/entenc.c
    ${OMI_OPUS_DIR}/find_LPC_FIX.c
    ${OMI_OPUS_DIR}/find_LTP_FIX.c
    ${OMI_OPUS_DIR}/find_pitch_lags_FIX.c
    ${OMI_OPUS_DIR}/find_pred_coefs_FIX.c
    ${OMI_OPUS_DIR}/gain_quant.c
    ${OMI_OPUS_DIR}/init_decoder.c
    ${OMI_OPUS_DIR}/init_encoder.c
    ${OMI_OPUS_DIR}/inner_prod_aligned.c
    ${OMI_OPUS_DIR}/interpolate.c
    ${OMI_OPUS_DIR}/k2a_FIX.c
    ${OMI_OPUS_DIR}/k2a_Q16_FIX.c
    ${OMI_OPUS_DIR}/kiss_fft.c
    ${OMI_OPUS_DIR}/laplace.c
    ${OMI_OPUS_DIR}/lin2log.c
    ${OMI_OPUS_DIR}/log2lin.c
    ${OMI_OPUS_DIR}/mathops.c
    ${OMI_OPUS_DIR}/mdct.c
    ${OMI_OPUS_DIR}/mlp.c
    ${OMI_OPUS_DIR}/mlp_data.c
    ${OMI_OPUS_DIR}/modes.c
    ${OMI_OPUS_DIR}/noise_shape_analysis_FIX.c
    ${OMI_OPUS_DIR}/opus.c
    ${OMI_OPUS_DIR}/opus_decoder.c
    ${OMI_OPUS_DIR}/opus_encoder.c
    ${OMI_OPUS_DIR}/opus_multistream.c
    ${OMI_OPUS_DIR}/opus_multistream_decoder.c
    ${OMI_OPUS_DIR}/opus_multistream_encoder.c
    ${OMI_OPUS_DIR}/pitch.c
    ${OMI_OPUS_DIR}/pitch_analysis_core_FIX.c
    ${OMI_OPUS_DIR}/pitch_est_tables.c
    ${OMI_OPUS_DIR}/process_NLSFs.c
    ${OMI_OPUS_DIR}/process_gains_FIX.c
    ${OMI_OPUS_DIR}/quant_LTP_gains.c
    ${OMI_OPUS_DIR}/quant_bands.c
    ${OMI_OPUS_DIR}/rate.c
    ${OMI_OPUS_DIR}/regularize_correlations_FIX.c
    ${OMI_OPUS_DIR}/repacketizer.c
    ${OMI_OPUS_DIR}/resampler.c
    ${OMI_OPUS_DIR}/resampler_down2.c
    ${OMI_OPUS_DIR}/resampler_down2_3.c
    ${OMI_OPUS_DIR}/resampler_private_AR2.c
    ${OMI_OPUS_DIR}/resampler_private_IIR_FIR.c
    ${OMI_OPUS_DIR}/resampler_private_down_FIR.c
    ${OMI_OPUS_DIR}/resampler_private_up2_HQ.c
    ${OMI_OPUS_DIR}/resampler_rom.c
    ${OMI_OPUS_DIR}/residual_energy16_FIX.c
    ${OMI_OPUS_DIR}/residual_energy_FIX.c
    ${OMI_OPUS_DIR}/schur64_FIX.c
    ${OMI_OPUS_DIR}/schur_FIX.c
    ${OMI_OPUS_DIR}/shell_coder.c
    ${OMI_OPUS_DIR}/sigm_Q15.c
    ${OMI_OPUS_DIR}/sort.c
    ${OMI_OPUS_DIR}/stereo_LR_to_MS.c
    ${OMI_OPUS_DIR}/stereo_MS_to_LR.c
    ${OMI_OPUS_DIR}/stereo_decode_pred.c
    ${OMI_OPUS_DIR}/stereo_encode_pred.c
    ${OMI_OPUS_DIR}/stereo_find_predictor.c
    ${OMI_OPUS_DIR}/stereo_quant_pred.c
    ${OMI_OPUS_DIR}/sum_sqr_shift.c
    ${OMI_OPUS_DIR}/table_LSF_cos.c
    ${OMI_OPUS_DIR}/tables_LTP.c
    ${OMI_OPUS_DIR}/tables_NLSF_CB_NB_MB.c
    ${OMI_OPUS_DIR}/tables_NLSF_CB_WB.c
    ${OMI_OPUS_DIR}/tables_gain.c
    ${OMI_OPUS_DIR}/tables_other.c
    ${OMI_OPUS_DIR}/tables_pitch_lag.c
    ${OMI_OPUS_DIR}/tables_pulses_per_block.c
    ${OMI_OPUS_DIR}/vector_ops_FIX.c
    ${OMI_OPUS_DIR}/vq.c
    ${OMI_OPUS_DIR}/warped_autocorrelation_FIX.c
    ${OMI_OPUS_DIR}/arm/celt_pitch_xcorr_arm_gcc.s
)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DARM_MATH_CM4")
# set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DVAR_ARRAYS")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DOPUS_ARM_ASM")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DOPUS_ARM_INLINE_ASM")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DOPUS_ARM_INLINE_EDSP")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DOPUS_ARM_INLINE_MEDIA")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DOPUS_ARM_MAY_HAVE_EDSP")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DOPUS_ARM_PRESUME_EDSP")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DOPUS_BUILD")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DUSE_ALLOCA")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DFIXED_POINT -DDISABLE_FLOAT_API")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DHAVE_CONFIG_H")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DHAVE_ALLOCA_H")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fsingle-precision-constant") # A lot of constants are written as doubles
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DHAVE_LRINT -DHAVE_LRINTF")

