import CryptoKit
import Foundation

enum SHA256 {
    static func hexDigest(of string: String) -> String {
        CryptoKit.SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func hexDigest(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return CryptoKit.SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
