# Aputure/Amaran BLE Protocol - Complete Technical Documentation

## Overview

This document details the complete reverse-engineered Bluetooth protocol for controlling Aputure and Amaran film lights. The protocol was discovered through APK decompilation of the official Sidus Link app and BLE packet capture analysis.

## Device Information

- **Tested Model:** Amaran 120C (appears as "SLCK Light" or "ALAM" in BLE scans)
- **Manufacturer:** Telink Semiconductor Co. Ltd
- **Connection Type:** Bluetooth Mesh (BLE GATT Proxy)
- **Firmware Platform:** Telink Mesh SDK

---

## Table of Contents

1. [Encryption Keys](#encryption-keys)
2. [Bluetooth Mesh Architecture](#bluetooth-mesh-architecture)
3. [Key Derivation Functions](#key-derivation-functions)
4. [Message Encryption Flow](#message-encryption-flow)
5. [Command Protocols](#command-protocols)
6. [BLE Service/Characteristic UUIDs](#ble-servicecharacteristic-uuids)
7. [Implementation Notes](#implementation-notes)

---

## Encryption Keys

### Source
Keys extracted from decompiled Sidus Link APK (`FastProvisioningConfiguration.java`)

### Network Key
Used for mesh network layer encryption.
```
Hex: 7D D7 36 4C D8 42 AD 18 C1 7C 74 65 6C 69 6E 6B
     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ t  e  l  i  n  k
```
Note: Last 6 bytes spell "telink" (Telink Semiconductor default)

### Application Key
Used for application layer encryption.
```
Hex: 63 96 47 71 73 4F BD 76 E3 B4 74 65 6C 69 6E 6B
                                     t  e  l  i  n  k
```

### IV Index
Initialization Vector for mesh network.
```
Value: 0x12345678
```

### Storage Encryption Key
Used for AES/ECB/PKCS7Padding encryption of app storage.
```
Key: "SidusLink_SLCKfp"
```

---

## Bluetooth Mesh Architecture

### Protocol Stack

```
+---------------------------+
|    Application Layer      |  <- 10-byte Sidus command payload
+---------------------------+
|   Access Layer (AES-CCM)  |  <- Encrypted with App Key
+---------------------------+
| Lower Transport (SEG/AKF) |  <- Segmentation headers
+---------------------------+
|  Network Layer (AES-CCM)  |  <- Encrypted with derived keys
+---------------------------+
|   Mesh Proxy PDU (GATT)   |  <- Written to characteristic
+---------------------------+
|    BLE GATT Transport     |
+---------------------------+
```

### Mesh Addresses

| Address Type | Value | Description |
|--------------|-------|-------------|
| Source (SRC) | 0x0001 | Our node address |
| Destination (DST) | 0xC000 | All devices group (broadcast) |
| Individual | 0x0001-0x7FFF | Single device unicast |
| Group | 0xC000-0xFEFF | Multicast groups |

### Message Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| TTL | 7 | Time To Live (hop count) |
| Opcode | 0xC0 + Vendor ID | Vendor model opcode |
| Vendor ID | 0x0211 | Telink vendor ID (little endian) |
| Default Opcode | 38 (0x26) | Sidus command opcode |

---

## Key Derivation Functions

### k2 Function - Network Key Derivation

Derives NID, Encryption Key, and Privacy Key from the Network Key.

```
Input: Network Key (N), P = [0x00]
Output: NID (7 bits), EncryptionKey (16 bytes), PrivacyKey (16 bytes)

Algorithm:
1. SALT = s1("smk2") = AES-CMAC(zeros, "smk2")
2. T = AES-CMAC(SALT, N)
3. T1 = AES-CMAC(T, P || 0x01)
4. T2 = AES-CMAC(T, T1 || P || 0x02)
5. T3 = AES-CMAC(T, T2 || P || 0x03)
6. NID = T1[15] & 0x7F
7. EncryptionKey = T2
8. PrivacyKey = T3
```

### k4 Function - Application Key Derivation

Derives AID (Application ID) from the Application Key.

```
Input: Application Key (N)
Output: AID (6 bits)

Algorithm:
1. SALT = s1("smk4") = AES-CMAC(zeros, "smk4")
2. T = AES-CMAC(SALT, N)
3. Result = AES-CMAC(T, "id6" || 0x01)
4. AID = Result[15] & 0x3F
```

### s1 Function - Salt Generation

```
s1(M) = AES-CMAC(zeros[16], M)
```

---

## Message Encryption Flow

### Step 1: Build Sidus Command Payload (10 bytes)

See [Command Protocols](#command-protocols) section below.

### Step 2: Build Access Message

```
Access Message = [Vendor Opcode (3 bytes)] + [Sidus Payload (10 bytes)]

Vendor Opcode:
  Byte 0: 0xC0 (vendor opcode marker)
  Byte 1: 0x11 (Telink Vendor ID low byte)
  Byte 2: 0x02 (Telink Vendor ID high byte)
```

### Step 3: Application Layer Encryption (AES-CCM)

```
Application Nonce (13 bytes):
  Byte 0:    0x01 (Application nonce type)
  Byte 1:    0x00 (ASZMIC || Pad)
  Bytes 2-4: SEQ (24-bit sequence number, big endian)
  Bytes 5-6: SRC (16-bit source address)
  Bytes 7-8: DST (16-bit destination address)
  Bytes 9-12: IV Index (32-bit)

Encrypted = AES-CCM(AppKey, AppNonce, AccessMessage, MIC=4 bytes)
```

### Step 4: Build Lower Transport PDU

```
Lower Transport Header:
  Bit 7:   SEG = 0 (unsegmented)
  Bit 6:   AKF = 1 (application key used)
  Bits 0-5: AID (from k4)

Lower Transport PDU = [Header (1 byte)] + [Encrypted Access]
```

### Step 5: Network Layer Encryption

```
Network Nonce (13 bytes):
  Byte 0:    0x00 (Network nonce type)
  Byte 1:    CTL || TTL (CTL=0 for access, TTL=7)
  Bytes 2-4: SEQ (24-bit)
  Bytes 5-6: SRC (16-bit)
  Bytes 7-8: 0x0000 (Pad)
  Bytes 9-12: IV Index (32-bit)

Plaintext = [DST (2 bytes)] + [Lower Transport PDU]
Encrypted = AES-CCM(EncryptionKey, NetNonce, Plaintext, MIC=4 bytes)
```

### Step 6: Privacy Obfuscation

Obfuscates CTL/TTL, SEQ, and SRC fields.

```
Privacy Random = EncDST[0:7] (padded if needed)

PECB Input (16 bytes):
  Bytes 0-4:  0x00 (zeros)
  Bytes 5-8:  IV Index (32-bit)
  Bytes 9-15: Privacy Random

PECB = AES-ECB(PrivacyKey, PECB Input)

Obfuscated = [CTL||TTL, SEQ[2], SEQ[1], SEQ[0], SRC[1], SRC[0]] XOR PECB[0:5]
```

### Step 7: Build Network PDU

```
NID byte:
  Bit 7:   IVI (IV Index bit 31)
  Bits 0-6: NID (from k2)

Network PDU = [NID byte] + [Obfuscated (6 bytes)] + [Encrypted Network]
```

### Step 8: Build Mesh Proxy PDU

```
Proxy PDU Header:
  Bits 6-7: SAR = 0x00 (complete message)
  Bits 0-5: Type = 0x01 (Network PDU)

Proxy PDU = [0x01] + [Network PDU]
```

### Step 9: Write to BLE Characteristic

Write the complete Proxy PDU to the Mesh Proxy Data In characteristic (0x2ADD).

---

## Command Protocols

All Sidus commands are 10 bytes with byte 0 as checksum.

### CCT Protocol (Command Type = 2)

Controls Color Temperature mode.

```
Byte Layout:
  Byte 0:    Checksum (sum of bytes 1-9)
  Bits 8-79: Bit-packed fields (LSB first)

Bit Fields (80 bits total):
  Bits 0-6:   Command Type = 2 (7 bits)
  Bit 7:      Always 1
  Bits 8-17:  Intensity (10 bits, 0-1000 = 0-100%)
  Bits 18-27: CCT Value (10 bits, 320-560 = 3200K-5600K)
  Bits 28-34: GM Value (7 bits)
  Bit 35:     GM High flag
  Bit 36:     GM Flag
  Bit 37:     CCT High flag
  Bit 38:     Auto Patch flag
  Bits 39-70: Reserved (zeros)
  Bit 71:     Sleep Mode
  Bits 72-79: Reserved

Parameters:
  intensity:  0-1000 (represents 0-100% * 10)
  cct:        320-560 (represents 3200K-5600K / 10)
  gm:         0-200 (100 = neutral green-magenta)
```

### HSI Protocol (Command Type = 1)

Controls HSI (Hue-Saturation-Intensity) mode.

```
Parameters:
  intensity:   0-1000 (0-100% * 10)
  hue:         0-360 degrees
  saturation:  0-100%
  cct:         Color temperature offset
  gm:          Green-magenta adjustment
```

### On/Off Protocol (Command Type = 0)

Simple power control.

```
10-byte format with power state in byte 9:
  Byte 9: 0x01 = ON, 0x00 = OFF
```

---

## BLE Service/Characteristic UUIDs

### Primary Control Path: Mesh Proxy Service

| Component | UUID | Properties |
|-----------|------|------------|
| **Mesh Proxy Service** | 0x1828 | - |
| Mesh Proxy Data In | 0x2ADD | Write Without Response |
| Mesh Proxy Data Out | 0x2ADE | Notify |

### Custom Aputure Services

| Component | UUID | Properties |
|-----------|------|------------|
| Control Service | 00010203-0405-0607-0809-0a0b0c0d1912 | - |
| Control Char | 00010203-0405-0607-0809-0a0b0c0d2b12 | Read, Write NR |
| Status Service | 00010203-0405-0607-0809-0a0b0c0d7fde | - |
| Status Char | 00010203-0405-0607-0809-0a0b0c0d7fdf | R, W NR, Notify, Indicate |

### Other Observed Services

| UUID | Description |
|------|-------------|
| 0x1800 | Generic Access |
| 0x180A | Device Information |
| 0x1801 | Generic Attribute |
| 0x7FDD | Mesh Provisioning |
| 0x7FD3 | Unknown (Telink?) |
| 0xFF01 | Unknown (OTA?) |

### Alternative Characteristics (for some devices)

| UUID | Description |
|------|-------------|
| 0xFF02 | Simple control (in service 0xFF01) |
| 0x7FCB | Alternative control |

---

## Implementation Notes

### Device Discovery

Aputure/Amaran lights may advertise with various names:
- "SLCK Light" (Sidus Link Controller Key)
- "ALAM" (Amaran Light)
- "Aputure", "Amaran", "Storm"
- Model-specific names

### Sequence Number Management

- Start at 1, increment for each message
- Must be unique per source address
- 24-bit value (0x000001 - 0xFFFFFF)

### Recommended Libraries

- **CryptoSwift** (Swift): AES-CCM, AES-CMAC implementations
- **nRF Mesh** (iOS): Full Bluetooth Mesh stack

### Debugging Tips

1. Log all BLE characteristics on connection
2. Monitor 0x2ADE for responses
3. Verify derived keys match expected values:
   - NID should be 7 bits from k2
   - AID should be 6 bits from k4
4. Check sequence number increments

### Known Issues

- Some devices disconnect if sent unexpected commands on connect
- IV Index may need to match device's current value
- Group address 0xC000 broadcasts to all devices

---

## APK Decompilation Reference

Key files from decompiled Sidus Link APK:

| File | Purpose |
|------|---------|
| FastProvisioningConfiguration.java | Default mesh keys |
| CCTProtocol.java | CCT command format |
| HSIProtocol.java | HSI command format |
| BinaryKit.java | Bit packing utilities |
| Encipher.java | Mesh encryption |
| MeshMessageClient.java | Message sending |
| BLEMeshNetwork.java | Network management |

---

## References

- [Bluetooth Mesh Specification](https://www.bluetooth.com/specifications/specs/mesh-model-1-1/)
- [Telink Mesh Wiki](https://wiki.telink-semi.cn/wiki/protocols/Telink-Mesh/)
- [nRF Mesh iOS Library](https://github.com/NordicSemiconductor/IOS-nRF-Mesh-Library)
- [telinkpp C++ Library](https://github.com/vpaeder/telinkpp)

---

## Changelog

- **2026-01-23**: Added complete mesh encryption documentation, key derivation functions
- **2026-01-22**: Initial protocol discovery, extracted keys from APK
