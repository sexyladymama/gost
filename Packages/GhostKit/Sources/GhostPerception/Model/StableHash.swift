/// Hachage non cryptographique stable (FNV-1a 64 bits), pour des identifiants
/// déterministes. `hashValue` de Swift change à chaque lancement.
enum StableHash {
    static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
