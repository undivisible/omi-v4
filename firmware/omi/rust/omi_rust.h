#ifndef OMI_RUST_H
#define OMI_RUST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int omi_rust_selftest(void);
void omi_rust_ring_header(uint16_t len, uint8_t *out);
void omi_rust_packet_header(uint16_t id, uint8_t index, uint8_t *out);

#ifdef __cplusplus
}
#endif

#endif
