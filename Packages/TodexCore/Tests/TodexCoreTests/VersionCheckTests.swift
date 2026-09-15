import Testing

@testable import TodexCore

@Suite
struct VersionCheckTests {
    @Test(arguments: ["DEV0.0.0", "dev0.0.0", "Dev-0.0.0", "0.0.0", " 0.0.0 ", "", nil])
    func devVersionsAreSkipped(version: String?) {
        #expect(VersionCheck.isDev(version))
        #expect(!VersionCheck.mismatch(app: version, backend: "1.2.3"))
        #expect(!VersionCheck.mismatch(app: "1.2.3", backend: version))
    }

    @Test
    func matchingReleaseVersionsPass() {
        #expect(!VersionCheck.mismatch(app: "1.2.3", backend: "1.2.3"))
        #expect(!VersionCheck.mismatch(app: "1.2.3", backend: "v1.2.3"))
        #expect(!VersionCheck.mismatch(app: " 1.2.3 ", backend: "1.2.3"))
    }

    @Test
    func differingReleaseVersionsMismatch() {
        #expect(VersionCheck.mismatch(app: "1.2.3", backend: "1.2.4"))
        #expect(VersionCheck.mismatch(app: "0.1.0", backend: "1.0.0"))
        #expect(VersionCheck.mismatch(app: "1.2.3", backend: nil) == false)
    }
}
