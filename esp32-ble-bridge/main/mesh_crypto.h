#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// Initialize mesh crypto with keys
void mesh_crypto_init(const uint8_t *network_key, const uint8_t *app_key,
                      uint32_t iv_index, uint16_t src_address);

// Check if crypto is initialized
bool mesh_crypto_is_initialized(void);

// Create a standard mesh proxy PDU from an access message.
// Returns PDU length, or 0 on failure. Output buffer must be >= 64 bytes.
int mesh_crypto_create_standard_pdu(const uint8_t *access_message, int access_len,
                                     uint16_t dst, uint8_t *out_pdu, int out_max);

// Create proxy filter setup PDU (blacklist mode).
// Returns PDU length, or 0 on failure. Output buffer must be >= 64 bytes.
int mesh_crypto_create_proxy_filter_setup(uint8_t *out_pdu, int out_max);

// Get current sequence number
uint32_t mesh_crypto_get_seq(void);

// Key derivation functions (exposed for testing)
void mesh_crypto_s1(const uint8_t *m, int m_len, uint8_t out[16]);
void mesh_crypto_k2(const uint8_t n[16], const uint8_t *p, int p_len,
                     uint8_t *out_nid, uint8_t out_enc[16], uint8_t out_priv[16]);
uint8_t mesh_crypto_k4(const uint8_t n[16]);
