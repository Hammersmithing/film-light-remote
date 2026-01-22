# Aputure/Amaran BLE Protocol

## Device Tested
- **Model:** Amaran 120C
- **MAC Address:** A4:C1:38:56:0B:2D
- **Manufacturer:** Telink Semiconductor Co. Ltd
- **Connection Type:** Bluetooth Mesh (Encrypted)

---

## Status: ENCRYPTED MESH

The Amaran 120C uses **encrypted Bluetooth Mesh** protocol (Sidus Mesh). Direct BLE writes do not work without proper mesh provisioning and encryption keys.

Standard Telink Mesh commands (0xF0, 0xF1) were tested but did not elicit a response from the light.

---

## Complete Service Map

| Service Name | UUID | Purpose |
|--------------|------|---------|
| Generic Access | 0x1800 | Standard BLE - device name, appearance |
| Device Information | 0x180A | Standard BLE - manufacturer info |
| Generic Attribute | 0x1801 | Standard BLE - service changed |
| Mesh Provisioning | 0x7FDD | Bluetooth Mesh setup |
| **Mesh Proxy** | **0x1828** | **Bluetooth Mesh proxy (likely control path)** |
| Control Service 1 | 00010203-0405-0607-0809-0a0b0c0d1912 | Custom Aputure service |
| Control Service 2 | 00010203-0405-0607-0809-0a0b0c0d7fde | Custom Aputure service |
| Unknown (Telink?) | 0x7FD3 | Possibly secondary control |
| Unknown (Telink?) | 0xFF01 | Possibly OTA or custom |

---

## Key Characteristics

### Control Service 1 (00010203-0405-0607-0809-0a0b0c0d1912)
| Characteristic | UUID | Properties |
|----------------|------|------------|
| Control | 00010203-0405-0607-0809-0a0b0c0d2b12 | READ, WRITE NO RESPONSE |

**Tested:** Writing 0xF0000000, 0xF0010000, 0xF1640000000000001 - No response

---

### Control Service 2 (00010203-0405-0607-0809-0a0b0c0d7fde)
| Characteristic | UUID | Properties |
|----------------|------|------------|
| Status | 00010203-0405-0607-0809-0a0b0c0d7fdf | INDICATE, NOTIFY, READ, WRITE NO RESPONSE |

---

### Mesh Proxy Service (0x1828)
This is likely the actual control path. Bluetooth Mesh messages would be sent through here with proper encryption.

---

### Service 0x7FD3
| Characteristic | UUID | Properties |
|----------------|------|------------|
| Unknown | 0x7FCB | NOTIFY, READ, WRITE NO RESPONSE |

---

### Service 0xFF01 (Telink custom)
| Characteristic | UUID | Properties |
|----------------|------|------------|
| Unknown | 0xFF02 | NOTIFY, READ, WRITE NO RESPONSE |

---

## Commands Tested (Did NOT work - encrypted)

Based on Telink Mesh protocol:
- `0xF0 0x00 0x00 0x00` - Power OFF (no response)
- `0xF0 0x01 0x00 0x00` - Power ON (no response)
- `0xF1 0x64 0x00 0x00 0x00 0x00 0x00 0x00 0x01` - Brightness 100% (no response)

The light uses encrypted Sidus Mesh, not plain Telink Mesh.

---

## Next Steps

### Option 1: Sidus Link Bridge (Recommended)
Purchase Sidus Link Bridge (~$70) which provides:
- Art-Net output (documented protocol)
- sACN output
- DMX output
Easy to control from any platform with standard lighting protocols.

### Option 2: Bluetooth Mesh Provisioning
Would require:
1. Proper Bluetooth Mesh provisioning to get network key
2. Application key exchange
3. Understanding of Sidus Mesh specifics
4. Likely encryption reverse engineering

### Option 3: Packet Capture
More sophisticated capture methods:
1. Use Bluetooth Mesh debugging tools
2. Decompile Sidus Link Android APK to find encryption details
3. Use hardware sniffer (nRF52840 with Mesh sniffer firmware)

### Option 4: DMX Control
If the light has DMX input, use standard DMX protocol instead of Bluetooth.

---

## References

- [telinkpp GitHub](https://github.com/vpaeder/telinkpp) - Telink Mesh C++ library (standard Telink, not Sidus)
- [Telink Mesh Wiki](https://wiki.telink-semi.cn/wiki/protocols/Telink-Mesh/)
- [Sidus Link Bridge](https://aputure.com/products/sidus-link-bridge) - Hardware bridge for Art-Net/DMX
- [Bitfocus Companion Request](https://github.com/bitfocus/companion-module-requests/issues/623) - Others seeking Aputure control

---

## UUIDs for iOS Implementation (for future use)

```swift
struct AmaranUUIDs {
    // Primary Control Service (encrypted - may not work directly)
    static let controlService = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d1912")
    static let controlCharacteristic = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d2b12")

    // Status/Feedback Service
    static let statusService = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d7fde")
    static let statusCharacteristic = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d7fdf")

    // Mesh Proxy (likely actual control path)
    static let meshProxyService = CBUUID(string: "1828")

    // Alternative services
    static let altService1 = CBUUID(string: "7FD3")
    static let altCharacteristic1 = CBUUID(string: "7FCB")

    static let altService2 = CBUUID(string: "FF01")
    static let altCharacteristic2 = CBUUID(string: "FF02")
}
```

---

## Notes

- Device uses Telink Semiconductor BLE chip
- Supports Bluetooth Mesh (encrypted)
- Sidus Link app uses proprietary "Sidus Mesh Technology"
- No public API available from Aputure
- Custom UUID pattern `00010203-0405-0607-0809-0a0b0c0d____` is Aputure-specific
