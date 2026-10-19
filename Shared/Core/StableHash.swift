import Foundation
import CryptoKit

/// Deterministischer, lauf-stabiler Textschlüssel (SHA-256-Hex). Dient der
/// Staleness-Erkennung beim Embedding (im Gegensatz zu Swifts nicht-stabilem hashValue).
public enum StableHash {
    public static func hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
