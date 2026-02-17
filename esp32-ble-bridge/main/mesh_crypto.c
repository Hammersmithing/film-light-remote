/*
 * mesh_crypto.c
 *
 * Bluetooth Mesh cryptography for ESP32 BLE bridge.
 * Port of MeshCrypto.swift to C using mbedtls.
 *
 * Uses manual RFC 3610 AES-CCM (same approach as the Swift implementation).
 */

#include "mesh_crypto.h"

#include <string.h>
#include <mbedtls/cipher.h>
#include <mbedtls/cmac.h>
#include <mbedtls/aes.h>
#include "esp_log.h"

static const char *TAG = "mesh_crypto";

// ---------------------------------------------------------------------------
// Static state
// ---------------------------------------------------------------------------

static uint8_t  s_network_key[16];
static uint8_t  s_app_key[16];
static uint32_t s_iv_index;
static uint16_t s_src_address;

static uint8_t  s_encryption_key[16];
static uint8_t  s_privacy_key[16];
static uint8_t  s_nid;
static uint8_t  s_aid;

static uint32_t s_sequence_number = 0x010000;  // Start high to avoid replay rejection

static bool s_initialized = false;

// ---------------------------------------------------------------------------
// Forward declarations (internal helpers)
// ---------------------------------------------------------------------------

static void aes_cmac(const uint8_t key[16], const uint8_t *msg, int msg_len,
                     uint8_t out[16]);
static void aes_ecb_block(const uint8_t key[16], const uint8_t in[16],
                          uint8_t out[16]);
static int  aes_ccm_encrypt(const uint8_t key[16], const uint8_t nonce[13],
                            const uint8_t *plaintext, int pt_len,
                            int mic_size, uint8_t *out);

static void build_application_nonce(uint32_t seq, uint16_t src, uint16_t dst,
                                    uint32_t iv_index, uint8_t nonce[13]);
static void build_network_nonce(uint8_t ctl, uint8_t ttl, uint32_t seq,
                                uint16_t src, uint32_t iv_index,
                                uint8_t nonce[13]);
static void obfuscate(uint8_t ctl_ttl, uint32_t seq, uint16_t src,
                      const uint8_t *enc_payload, const uint8_t priv_key[16],
                      uint32_t iv_index, uint8_t out[6]);

// ---------------------------------------------------------------------------
// Key derivation: s1
// ---------------------------------------------------------------------------

void mesh_crypto_s1(const uint8_t *m, int m_len, uint8_t out[16])
{
    uint8_t zero[16];
    memset(zero, 0, sizeof(zero));
    aes_cmac(zero, m, m_len, out);
}

// ---------------------------------------------------------------------------
// Key derivation: k2
// ---------------------------------------------------------------------------

void mesh_crypto_k2(const uint8_t n[16], const uint8_t *p, int p_len,
                    uint8_t *out_nid, uint8_t out_enc[16], uint8_t out_priv[16])
{
    // SALT = s1("smk2")
    const uint8_t smk2[] = { 's', 'm', 'k', '2' };
    uint8_t salt[16];
    mesh_crypto_s1(smk2, 4, salt);

    // T = AES-CMAC(SALT, N)
    uint8_t t[16];
    aes_cmac(salt, n, 16, t);

    // T1 = AES-CMAC(T, P || 0x01)
    uint8_t t1_input[64];  // p_len + 1, safe upper bound
    memcpy(t1_input, p, p_len);
    t1_input[p_len] = 0x01;
    uint8_t t1[16];
    aes_cmac(t, t1_input, p_len + 1, t1);

    // T2 = AES-CMAC(T, T1 || P || 0x02)
    uint8_t t2_input[64];
    memcpy(t2_input, t1, 16);
    memcpy(t2_input + 16, p, p_len);
    t2_input[16 + p_len] = 0x02;
    uint8_t t2[16];
    aes_cmac(t, t2_input, 16 + p_len + 1, t2);

    // T3 = AES-CMAC(T, T2 || P || 0x03)
    uint8_t t3_input[64];
    memcpy(t3_input, t2, 16);
    memcpy(t3_input + 16, p, p_len);
    t3_input[16 + p_len] = 0x03;
    uint8_t t3[16];
    aes_cmac(t, t3_input, 16 + p_len + 1, t3);

    // NID = T1[15] & 0x7F
    *out_nid = t1[15] & 0x7F;

    // Encryption Key = T2, Privacy Key = T3
    memcpy(out_enc, t2, 16);
    memcpy(out_priv, t3, 16);
}

// ---------------------------------------------------------------------------
// Key derivation: k4
// ---------------------------------------------------------------------------

uint8_t mesh_crypto_k4(const uint8_t n[16])
{
    // SALT = s1("smk4")
    const uint8_t smk4[] = { 's', 'm', 'k', '4' };
    uint8_t salt[16];
    mesh_crypto_s1(smk4, 4, salt);

    // T = AES-CMAC(SALT, N)
    uint8_t t[16];
    aes_cmac(salt, n, 16, t);

    // AID = AES-CMAC(T, "id6" || 0x01)[15] & 0x3F
    const uint8_t id6[] = { 'i', 'd', '6', 0x01 };
    uint8_t result[16];
    aes_cmac(t, id6, 4, result);

    return result[15] & 0x3F;
}

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

void mesh_crypto_init(const uint8_t *network_key, const uint8_t *app_key,
                      uint32_t iv_index, uint16_t src_address)
{
    memcpy(s_network_key, network_key, 16);
    memcpy(s_app_key, app_key, 16);
    s_iv_index = iv_index;
    s_src_address = src_address;

    ESP_LOGI(TAG, "IV Index = 0x%08lX, SRC = 0x%04X",
             (unsigned long)s_iv_index, s_src_address);

    // Derive NID, encryption key, privacy key via k2
    const uint8_t p[] = { 0x00 };
    mesh_crypto_k2(s_network_key, p, 1,
                   &s_nid, s_encryption_key, s_privacy_key);

    // Derive AID from app key via k4
    s_aid = mesh_crypto_k4(s_app_key);

    s_initialized = true;

    ESP_LOGI(TAG, "NID = 0x%02X, AID = 0x%02X", s_nid, s_aid);

    ESP_LOGI(TAG, "EncKey = %02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X",
             s_encryption_key[0],  s_encryption_key[1],
             s_encryption_key[2],  s_encryption_key[3],
             s_encryption_key[4],  s_encryption_key[5],
             s_encryption_key[6],  s_encryption_key[7],
             s_encryption_key[8],  s_encryption_key[9],
             s_encryption_key[10], s_encryption_key[11],
             s_encryption_key[12], s_encryption_key[13],
             s_encryption_key[14], s_encryption_key[15]);
}

bool mesh_crypto_is_initialized(void)
{
    return s_initialized;
}

uint32_t mesh_crypto_get_seq(void)
{
    return s_sequence_number;
}

// ---------------------------------------------------------------------------
// Nonce builders
// ---------------------------------------------------------------------------

static void build_application_nonce(uint32_t seq, uint16_t src, uint16_t dst,
                                    uint32_t iv_index, uint8_t nonce[13])
{
    memset(nonce, 0, 13);
    nonce[0]  = 0x01;                          // Application nonce type
    nonce[1]  = 0x00;                          // ASZMIC || Pad
    nonce[2]  = (uint8_t)((seq >> 16) & 0xFF);
    nonce[3]  = (uint8_t)((seq >>  8) & 0xFF);
    nonce[4]  = (uint8_t)( seq        & 0xFF);
    nonce[5]  = (uint8_t)((src >>  8) & 0xFF);
    nonce[6]  = (uint8_t)( src        & 0xFF);
    nonce[7]  = (uint8_t)((dst >>  8) & 0xFF);
    nonce[8]  = (uint8_t)( dst        & 0xFF);
    nonce[9]  = (uint8_t)((iv_index >> 24) & 0xFF);
    nonce[10] = (uint8_t)((iv_index >> 16) & 0xFF);
    nonce[11] = (uint8_t)((iv_index >>  8) & 0xFF);
    nonce[12] = (uint8_t)( iv_index        & 0xFF);
}

static void build_network_nonce(uint8_t ctl, uint8_t ttl, uint32_t seq,
                                uint16_t src, uint32_t iv_index,
                                uint8_t nonce[13])
{
    memset(nonce, 0, 13);
    nonce[0]  = 0x00;                          // Network nonce type
    nonce[1]  = (ctl << 7) | (ttl & 0x7F);
    nonce[2]  = (uint8_t)((seq >> 16) & 0xFF);
    nonce[3]  = (uint8_t)((seq >>  8) & 0xFF);
    nonce[4]  = (uint8_t)( seq        & 0xFF);
    nonce[5]  = (uint8_t)((src >>  8) & 0xFF);
    nonce[6]  = (uint8_t)( src        & 0xFF);
    nonce[7]  = 0x00;                          // Pad
    nonce[8]  = 0x00;                          // Pad
    nonce[9]  = (uint8_t)((iv_index >> 24) & 0xFF);
    nonce[10] = (uint8_t)((iv_index >> 16) & 0xFF);
    nonce[11] = (uint8_t)((iv_index >>  8) & 0xFF);
    nonce[12] = (uint8_t)( iv_index        & 0xFF);
}

// ---------------------------------------------------------------------------
// Obfuscation
// ---------------------------------------------------------------------------

static void obfuscate(uint8_t ctl_ttl, uint32_t seq, uint16_t src,
                      const uint8_t *enc_payload, const uint8_t priv_key[16],
                      uint32_t iv_index, uint8_t out[6])
{
    // Privacy Random = first 7 bytes of the encrypted network payload
    uint8_t privacy_random[7];
    memcpy(privacy_random, enc_payload, 7);

    // PECB input = 0x0000000000 || IV Index || Privacy Random
    uint8_t pecb_input[16];
    memset(pecb_input, 0, 5);
    pecb_input[5]  = (uint8_t)((iv_index >> 24) & 0xFF);
    pecb_input[6]  = (uint8_t)((iv_index >> 16) & 0xFF);
    pecb_input[7]  = (uint8_t)((iv_index >>  8) & 0xFF);
    pecb_input[8]  = (uint8_t)( iv_index        & 0xFF);
    memcpy(pecb_input + 9, privacy_random, 7);

    // PECB = AES-ECB(PrivacyKey, pecb_input)
    uint8_t pecb[16];
    aes_ecb_block(priv_key, pecb_input, pecb);

    // Header = CTL/TTL || SEQ[2] || SEQ[1] || SEQ[0] || SRC[1] || SRC[0]
    uint8_t header[6];
    header[0] = ctl_ttl;
    header[1] = (uint8_t)((seq >> 16) & 0xFF);
    header[2] = (uint8_t)((seq >>  8) & 0xFF);
    header[3] = (uint8_t)( seq        & 0xFF);
    header[4] = (uint8_t)((src >>  8) & 0xFF);
    header[5] = (uint8_t)( src        & 0xFF);

    // XOR with first 6 bytes of PECB
    for (int i = 0; i < 6; i++) {
        out[i] = header[i] ^ pecb[i];
    }
}

// ---------------------------------------------------------------------------
// Crypto primitives
// ---------------------------------------------------------------------------

/**
 * AES-CMAC using mbedtls_cipher_cmac().
 */
static void aes_cmac(const uint8_t key[16], const uint8_t *msg, int msg_len,
                     uint8_t out[16])
{
    const mbedtls_cipher_info_t *cipher_info =
        mbedtls_cipher_info_from_type(MBEDTLS_CIPHER_AES_128_ECB);

    int ret = mbedtls_cipher_cmac(cipher_info, key, 128,
                                  msg, (size_t)msg_len, out);
    if (ret != 0) {
        ESP_LOGE(TAG, "AES-CMAC failed: -0x%04X", (unsigned)-ret);
        memset(out, 0, 16);
    }
}

/**
 * AES-128 ECB encrypt a single 16-byte block.
 */
static void aes_ecb_block(const uint8_t key[16], const uint8_t in_block[16],
                          uint8_t out_block[16])
{
    mbedtls_aes_context ctx;
    mbedtls_aes_init(&ctx);

    int ret = mbedtls_aes_setkey_enc(&ctx, key, 128);
    if (ret != 0) {
        ESP_LOGE(TAG, "AES set key failed: -0x%04X", (unsigned)-ret);
        memset(out_block, 0, 16);
        mbedtls_aes_free(&ctx);
        return;
    }

    ret = mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_ENCRYPT, in_block, out_block);
    if (ret != 0) {
        ESP_LOGE(TAG, "AES ECB failed: -0x%04X", (unsigned)-ret);
        memset(out_block, 0, 16);
    }

    mbedtls_aes_free(&ctx);
}

/**
 * AES-CCM encrypt - Manual implementation per RFC 3610.
 *
 * Parameters:
 *   key       - 16-byte AES key
 *   nonce     - 13-byte nonce
 *   plaintext - input data
 *   pt_len    - length of plaintext
 *   mic_size  - 4 or 8 bytes
 *   out       - output buffer (must hold pt_len + mic_size bytes)
 *
 * Returns total output length (pt_len + mic_size), or 0 on failure.
 */
static int aes_ccm_encrypt(const uint8_t key[16], const uint8_t nonce[13],
                           const uint8_t *plaintext, int pt_len,
                           int mic_size, uint8_t *out)
{
    if (mic_size != 4 && mic_size != 8) {
        ESP_LOGE(TAG, "CCM MIC must be 4 or 8 bytes");
        return 0;
    }

    // CCM parameters for 13-byte nonce: L = 2
    const int L = 2;

    // === Step 1: Generate MIC using CBC-MAC ===

    // B_0 flags: Reserved(1) | Adata(1) | M'(3) | L'(3)
    //   Adata = 0 (no associated data)
    //   M' = (micSize - 2) / 2
    //   L' = L - 1 = 1
    uint8_t flags_b0 = (uint8_t)(((mic_size - 2) / 2) << 3) | (uint8_t)(L - 1);

    uint8_t b0[16];
    b0[0] = flags_b0;
    memcpy(b0 + 1, nonce, 13);
    b0[14] = (uint8_t)((pt_len >> 8) & 0xFF);
    b0[15] = (uint8_t)( pt_len       & 0xFF);

    // CBC-MAC: X_1 = AES(K, B_0)
    uint8_t cbc_state[16];
    aes_ecb_block(key, b0, cbc_state);

    // Process plaintext blocks
    int num_blocks = (pt_len + 15) / 16;
    for (int i = 0; i < num_blocks; i++) {
        uint8_t block[16];
        memset(block, 0, 16);
        int start = i * 16;
        int end = start + 16;
        if (end > pt_len) end = pt_len;
        for (int j = start; j < end; j++) {
            block[j - start] = plaintext[j];
        }
        // XOR with previous CBC state
        for (int j = 0; j < 16; j++) {
            block[j] ^= cbc_state[j];
        }
        aes_ecb_block(key, block, cbc_state);
    }

    // Tag = first mic_size bytes of CBC-MAC result
    uint8_t tag[8];
    memcpy(tag, cbc_state, mic_size);

    // === Step 2: CTR encryption ===

    uint8_t flags_ctr = (uint8_t)(L - 1);

    // A_0 for encrypting the tag
    uint8_t a0[16];
    a0[0] = flags_ctr;
    memcpy(a0 + 1, nonce, 13);
    a0[14] = 0;
    a0[15] = 0;

    uint8_t s0[16];
    aes_ecb_block(key, a0, s0);

    // Encrypt the tag to produce MIC
    uint8_t mic[8];
    for (int i = 0; i < mic_size; i++) {
        mic[i] = tag[i] ^ s0[i];
    }

    // Encrypt plaintext with A_1, A_2, ...
    for (int i = 0; i < num_blocks; i++) {
        int counter = i + 1;
        uint8_t ai[16];
        ai[0] = flags_ctr;
        memcpy(ai + 1, nonce, 13);
        ai[14] = (uint8_t)((counter >> 8) & 0xFF);
        ai[15] = (uint8_t)( counter       & 0xFF);

        uint8_t si[16];
        aes_ecb_block(key, ai, si);

        int start = i * 16;
        int end = start + 16;
        if (end > pt_len) end = pt_len;
        for (int j = start; j < end; j++) {
            out[j] = plaintext[j] ^ si[j - start];
        }
    }

    // Append MIC
    memcpy(out + pt_len, mic, mic_size);

    return pt_len + mic_size;
}

// ---------------------------------------------------------------------------
// Create standard mesh proxy PDU
// ---------------------------------------------------------------------------

int mesh_crypto_create_standard_pdu(const uint8_t *access_message, int access_len,
                                    uint16_t dst, uint8_t *out_pdu, int out_max)
{
    if (!s_initialized) {
        ESP_LOGE(TAG, "Not initialized");
        return 0;
    }

    s_sequence_number++;
    uint32_t seq = s_sequence_number;
    uint16_t src = s_src_address;
    uint8_t ttl = 7;

    ESP_LOGI(TAG, "[Std] dst=0x%04X seq=0x%06lX access_len=%d",
             dst, (unsigned long)seq, access_len);

    // --- Encrypt access layer with app key (AES-CCM, 4-byte MIC) ---

    uint8_t app_nonce[13];
    build_application_nonce(seq, src, dst, s_iv_index, app_nonce);

    uint8_t encrypted_access[64];  // access_len + 4
    int enc_access_len = aes_ccm_encrypt(s_app_key, app_nonce,
                                         access_message, access_len,
                                         4, encrypted_access);
    if (enc_access_len == 0) {
        ESP_LOGE(TAG, "[Std] Failed to encrypt access layer");
        return 0;
    }

    // --- Build lower transport PDU (unsegmented access message) ---
    // SEG=0, AKF=1, AID (6 bits)
    uint8_t ltp_header = (0 << 7) | (1 << 6) | (s_aid & 0x3F);

    uint8_t lower_transport[64];
    lower_transport[0] = ltp_header;
    memcpy(lower_transport + 1, encrypted_access, enc_access_len);
    int ltp_len = 1 + enc_access_len;

    // --- Build network PDU ---
    uint8_t ivi = (uint8_t)(s_iv_index & 0x01);
    uint8_t nid_byte = (ivi << 7) | (s_nid & 0x7F);
    uint8_t ctl_ttl = (0 << 7) | (ttl & 0x7F);  // CTL=0 for access message

    uint8_t net_nonce[13];
    build_network_nonce(0, ttl, seq, src, s_iv_index, net_nonce);

    // DST + lower transport PDU
    uint8_t dst_transport[64];
    dst_transport[0] = (uint8_t)((dst >> 8) & 0xFF);
    dst_transport[1] = (uint8_t)( dst       & 0xFF);
    memcpy(dst_transport + 2, lower_transport, ltp_len);
    int dst_transport_len = 2 + ltp_len;

    // Encrypt with network key (4-byte NetMIC for unsegmented)
    uint8_t encrypted_net[64];
    int enc_net_len = aes_ccm_encrypt(s_encryption_key, net_nonce,
                                      dst_transport, dst_transport_len,
                                      4, encrypted_net);
    if (enc_net_len == 0) {
        ESP_LOGE(TAG, "[Std] Failed to encrypt network layer");
        return 0;
    }

    // --- Obfuscate ---
    uint8_t obfuscated_header[6];
    obfuscate(ctl_ttl, seq, src, encrypted_net, s_privacy_key,
              s_iv_index, obfuscated_header);

    // --- Assemble final proxy PDU ---
    // Proxy header (1) + NID (1) + obfuscated (6) + encrypted net payload
    int network_pdu_len = 1 + 6 + enc_net_len;
    int total_len = 1 + network_pdu_len;  // proxy header + network PDU

    if (total_len > out_max) {
        ESP_LOGE(TAG, "[Std] Output buffer too small (%d > %d)", total_len, out_max);
        return 0;
    }

    int pos = 0;

    // Proxy PDU header: SAR=complete (0x00), Type=Network PDU (0x00) => 0x00
    out_pdu[pos++] = 0x00;

    // IVI/NID byte
    out_pdu[pos++] = nid_byte;

    // Obfuscated header (6 bytes)
    memcpy(out_pdu + pos, obfuscated_header, 6);
    pos += 6;

    // Encrypted network payload
    memcpy(out_pdu + pos, encrypted_net, enc_net_len);
    pos += enc_net_len;

    ESP_LOGI(TAG, "[Std] Proxy PDU (%d bytes)", pos);

    return pos;
}

// ---------------------------------------------------------------------------
// Create proxy filter setup PDU
// ---------------------------------------------------------------------------

int mesh_crypto_create_proxy_filter_setup(uint8_t *out_pdu, int out_max)
{
    if (!s_initialized) {
        ESP_LOGE(TAG, "Not initialized");
        return 0;
    }

    s_sequence_number++;
    uint32_t seq = s_sequence_number;
    uint16_t src = s_src_address;
    uint16_t dst = 0x0000;  // Proxy config messages use DST=0x0000

    // Lower transport PDU for unsegmented control message:
    // Byte 0: SEG=0 (bit 7) | Opcode (bits 6-0) = 0x00 (Set Filter Type)
    // Byte 1: FilterType = 0x01 (blacklist = accept all)
    uint8_t lower_transport_pdu[2] = { 0x00, 0x01 };
    int ltp_len = 2;

    // Network layer: CTL=1 (control message), TTL=0 (not relayed)
    uint8_t ivi = (uint8_t)(s_iv_index & 0x01);
    uint8_t nid_byte = (ivi << 7) | (s_nid & 0x7F);
    uint8_t ctl_ttl = (1 << 7) | (0 & 0x7F);  // CTL=1, TTL=0

    uint8_t net_nonce[13];
    build_network_nonce(1, 0, seq, src, s_iv_index, net_nonce);

    // DST + lower transport PDU
    uint8_t dst_transport[64];
    dst_transport[0] = (uint8_t)((dst >> 8) & 0xFF);
    dst_transport[1] = (uint8_t)( dst       & 0xFF);
    memcpy(dst_transport + 2, lower_transport_pdu, ltp_len);
    int dst_transport_len = 2 + ltp_len;

    // CTL=1 => 8-byte NetMIC (64-bit)
    uint8_t encrypted_net[64];
    int enc_net_len = aes_ccm_encrypt(s_encryption_key, net_nonce,
                                      dst_transport, dst_transport_len,
                                      8, encrypted_net);
    if (enc_net_len == 0) {
        ESP_LOGE(TAG, "Failed to encrypt proxy filter config");
        return 0;
    }

    // Obfuscate
    uint8_t obfuscated_header[6];
    obfuscate(ctl_ttl, seq, src, encrypted_net, s_privacy_key,
              s_iv_index, obfuscated_header);

    // Assemble final proxy PDU
    int network_pdu_len = 1 + 6 + enc_net_len;
    int total_len = 1 + network_pdu_len;

    if (total_len > out_max) {
        ESP_LOGE(TAG, "Output buffer too small (%d > %d)", total_len, out_max);
        return 0;
    }

    int pos = 0;

    // Proxy PDU header: SAR=complete (0x00), Type=Proxy Configuration (0x02) => 0x02
    out_pdu[pos++] = 0x02;

    // IVI/NID byte
    out_pdu[pos++] = nid_byte;

    // Obfuscated header (6 bytes)
    memcpy(out_pdu + pos, obfuscated_header, 6);
    pos += 6;

    // Encrypted network payload
    memcpy(out_pdu + pos, encrypted_net, enc_net_len);
    pos += enc_net_len;

    ESP_LOGI(TAG, "Proxy Filter Setup PDU (%d bytes)", pos);

    return pos;
}
