import Foundation

extension NativeMeshProvisioning {
    static func provisioningPduSummary(_ pdu: [UInt8]) -> [String: Any] {
        guard let pduType = pdu.first else {
            return [
                "bytes": 0,
                "decode_error": "empty provisioning PDU"
            ]
        }

        var result: [String: Any] = [
            "bytes": pdu.count,
            "pdu_type": Int(pduType),
            "pdu_type_name": provisioningPduTypeName(pduType)
        ]
        if let capabilities = provisioningCapabilitiesSummary(pdu) {
            result["capabilities"] = capabilities
        } else if let start = provisioningStartSummary(pdu) {
            result["start"] = start
        } else if pduType == provisioningPublicKeyType {
            result["public_key_bytes"] = max(0, pdu.count - 1)
        } else if pduType == provisioningConfirmationType {
            result["confirmation_bytes"] = max(0, pdu.count - 1)
        } else if pduType == provisioningRandomType {
            result["random_bytes"] = max(0, pdu.count - 1)
        } else if pduType == provisioningDataType {
            result["encrypted_data_bytes"] = max(0, pdu.count - 9)
            result["mic_bytes"] = pdu.count >= 9 ? 8 : 0
        } else if pduType == provisioningCompleteType {
            result["complete"] = pdu.count == 1
        } else if pduType == provisioningFailedType {
            result["failed"] = provisioningFailedSummary(pdu)
        }
        return result
    }

    static func provisioningStartSummary(_ pdu: [UInt8]) -> [String: Any]? {
        guard pdu.count == 6, pdu[0] == provisioningStartType else {
            return nil
        }
        return [
            "pdu_type": Int(pdu[0]),
            "pdu_type_name": "provisioning_start",
            "algorithm": Int(pdu[1]),
            "algorithm_name": provisioningAlgorithmName(pdu[1]),
            "public_key": Int(pdu[2]),
            "public_key_name": pdu[2] == publicKeyOob ? "oob" : "in_band",
            "authentication_method": Int(pdu[3]),
            "authentication_method_name": authenticationMethodName(pdu[3]),
            "authentication_action": Int(pdu[4]),
            "authentication_size": Int(pdu[5])
        ]
    }

    static func provisioningCapabilitiesSummary(_ pdu: [UInt8]) -> [String: Any]? {
        guard pdu.count == 12, pdu[0] == provisioningCapabilitiesType else {
            return nil
        }

        let algorithms = bigEndianUInt16(pdu, offset: 2)
        let publicKeyType = pdu[4]
        let staticOobType = pdu[5]
        let outputOobAction = bigEndianUInt16(pdu, offset: 7)
        let inputOobAction = bigEndianUInt16(pdu, offset: 10)

        return [
            "pdu_type": Int(pdu[0]),
            "pdu_type_name": "provisioning_capabilities",
            "number_of_elements": Int(pdu[1]),
            "algorithms": String(format: "0x%04x", algorithms),
            "algorithm_flags": algorithmFlags(algorithms),
            "public_key_type": Int(publicKeyType),
            "public_key_oob": (publicKeyType & 0x01) != 0,
            "static_oob_type": Int(staticOobType),
            "static_oob_available": (staticOobType & 0x01) != 0,
            "output_oob_size": Int(pdu[6]),
            "output_oob_action": String(format: "0x%04x", outputOobAction),
            "output_oob_actions": outputOobActionFlags(outputOobAction),
            "input_oob_size": Int(pdu[9]),
            "input_oob_action": String(format: "0x%04x", inputOobAction),
            "input_oob_actions": inputOobActionFlags(inputOobAction)
        ]
    }

    static func algorithmFlags(_ value: UInt16) -> [String] {
        let known: [(UInt16, String)] = [
            (0x0001, "fips_p256_elliptic_curve"),
            (0x0002, "fips_p256_hmac_sha256_aes_ccm")
        ]
        return known.compactMap { item in
            let (mask, name) = item
            return (value & mask) != 0 ? name : nil
        }
    }

    static func outputOobActionFlags(_ value: UInt16) -> [String] {
        let known: [(UInt16, String)] = [
            (0x0001, "blink"),
            (0x0002, "beep"),
            (0x0004, "vibrate"),
            (0x0008, "output_numeric"),
            (0x0010, "output_alphanumeric")
        ]
        return known.compactMap { item in
            let (mask, name) = item
            return (value & mask) != 0 ? name : nil
        }
    }

    static func inputOobActionFlags(_ value: UInt16) -> [String] {
        let known: [(UInt16, String)] = [
            (0x0001, "push"),
            (0x0002, "twist"),
            (0x0004, "input_numeric"),
            (0x0008, "input_alphanumeric")
        ]
        return known.compactMap { item in
            let (mask, name) = item
            return (value & mask) != 0 ? name : nil
        }
    }

    static func provisioningPduTypeName(_ value: UInt8) -> String {
        let names: [UInt8: String] = [
            0x00: "provisioning_invite",
            0x01: "provisioning_capabilities",
            0x02: "provisioning_start",
            0x03: "provisioning_public_key",
            0x04: "provisioning_input_complete",
            0x05: "provisioning_confirmation",
            0x06: "provisioning_random",
            0x07: "provisioning_data",
            0x08: "provisioning_complete",
            0x09: "provisioning_failed"
        ]
        return names[value] ?? "unknown"
    }

    static func provisioningFailedSummary(_ pdu: [UInt8]) -> [String: Any] {
        guard pdu.count == 2, pdu[0] == provisioningFailedType else {
            return ["bytes": pdu.count]
        }
        return [
            "error_code": Int(pdu[1]),
            "error_name": provisioningFailedErrorName(pdu[1])
        ]
    }

    static func provisioningFailedErrorName(_ value: UInt8) -> String {
        switch value {
        case 0x01: return "invalid_pdu"
        case 0x02: return "invalid_format"
        case 0x03: return "unexpected_pdu"
        case 0x04: return "confirmation_failed"
        case 0x05: return "out_of_resources"
        case 0x06: return "decryption_failed"
        case 0x07: return "unexpected_error"
        case 0x08: return "cannot_assign_addresses"
        default: return "unknown"
        }
    }

    static func provisioningAlgorithmName(_ value: UInt8) -> String {
        switch value {
        case algorithmFipsP256EllipticCurve: return "fips_p256_elliptic_curve"
        case 0x01: return "fips_p256_hmac_sha256_aes_ccm"
        default: return "unknown"
        }
    }

    static func authenticationMethodName(_ value: UInt8) -> String {
        switch value {
        case authenticationNoOob: return "no_oob"
        case authenticationStaticOob: return "static_oob"
        case authenticationOutputOob: return "output_oob"
        case authenticationInputOob: return "input_oob"
        default: return "unknown"
        }
    }
}
