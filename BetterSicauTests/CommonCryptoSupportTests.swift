import XCTest
@testable import Better_Sicau

final class CommonCryptoSupportTests: XCTestCase {
    func testMD5Vector() {
        XCTAssertEqual(
            CommonCryptoSupport.md5(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined(),
            "900150983cd24fb0d6963f7d28e17f72"
        )
    }

    func testAES128CBCVector() throws {
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")
        let iv = Data(hex: "000102030405060708090a0b0c0d0e0f")
        let ciphertext = Data(hex: "630dd87b14efafb925a1fbd9b2bd32f848ccab2899c64d2d41eadfe46c96a1f4")
        let plaintext = try CommonCryptoSupport.aes128CBCDecrypt(ciphertext, key: key, iv: iv)
        XCTAssertEqual(plaintext, Data("Sixteen byte msg".utf8))
    }
}

private extension Data {
    init(hex value: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            bytes.append(UInt8(value[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
