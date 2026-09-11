import Foundation
import CoreFoundation

nonisolated enum ClassicASPFormEncoder {
    /// Encode x-www-form-urlencoded data using the GB18030 superset expected
    /// by the legacy SICAU ASP endpoints.
    static func encode(_ fields: [AcademicHTMLParser.FormField]) -> Data {
        let body = fields.map { "\(encodeComponent($0.name))=\(encodeComponent($0.value))" }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func string(_ fields: [AcademicHTMLParser.FormField]) -> String {
        String(data: encode(fields), encoding: .ascii) ?? ""
    }

    static func overriding(_ fields: [AcademicHTMLParser.FormField], with overrides: [String: String]) -> [AcademicHTMLParser.FormField] {
        guard !overrides.isEmpty else { return fields }
        var output = fields
        for (name, value) in overrides where !name.isEmpty {
            if let firstIndex = output.firstIndex(where: { $0.name == name }) {
                output[firstIndex].value = value
                var index = output.index(after: firstIndex)
                while index < output.endIndex {
                    if output[index].name == name {
                        output.remove(at: index)
                    } else {
                        index = output.index(after: index)
                    }
                }
            } else {
                output.append(.init(name: name, value: value))
            }
        }
        return output
    }

    private static func encodeComponent(_ value: String) -> String {
        let bytes = encodedBytes(value)
        return bytes.map { byte in
            if byte == 0x20 { return "+" }
            if isSafe(byte) { return String(UnicodeScalar(byte)) }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    private static func encodedBytes(_ value: String) -> [UInt8] {
        // CFStringEncodingExt exposes GB18030 as 0x0632 on Apple platforms;
        // using the value keeps this source compatible with older SDK overlays.
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632)))
        if let data = value.data(using: encoding, allowLossyConversion: false) {
            return Array(data)
        }
        return Array(value.utf8)
    }

    private static func isSafe(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
            || byte == 0x2A || byte == 0x2D || byte == 0x2E || byte == 0x5F
    }
}
