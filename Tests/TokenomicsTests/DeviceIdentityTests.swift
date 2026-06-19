import Testing
import Foundation
@testable import Tokenomics

@Suite("DeviceIdentity")
struct DeviceIdentityTests {

    @Test("mints a UUID once and reuses it from the file")
    func mintsAndPersists() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = DeviceIdentity.loadOrCreateID(at: url)
        let second = DeviceIdentity.loadOrCreateID(at: url)
        #expect(!first.isEmpty)
        #expect(first == second)             // reused from disk, not re-minted
    }

    @Test("falls back to a non-empty id when no file location is available")
    func fallbackWhenNoURL() {
        #expect(!DeviceIdentity.loadOrCreateID(at: nil).isEmpty)
    }

    @Test("display name uses the trimmed override when set")
    func displayNameOverride() throws {
        let defaults = try #require(UserDefaults(suiteName: "devid-\(UUID().uuidString)"))
        defaults.set("  My Studio  ", forKey: DeviceIdentity.displayNameKey)
        #expect(DeviceIdentity.displayName(defaults) == "My Studio")
    }

    @Test("display name falls back to a non-empty default without an override")
    func displayNameFallback() throws {
        let defaults = try #require(UserDefaults(suiteName: "devid-empty-\(UUID().uuidString)"))
        #expect(!DeviceIdentity.displayName(defaults).isEmpty)
    }
}
