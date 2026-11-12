import Foundation
import Testing
@testable import DustlingCore

@Suite struct CodeIdentityTests {
    @Test func runningLocationClassifiesPaths() {
        func location(_ path: String) -> RunningLocation {
            CodeIdentity.runningLocation(bundleURL: URL(filePath: path))
        }
        #expect(location("/private/var/folders/x/AppTranslocation/ABC/d/Dustling.app") == .translocated)
        #expect(location("/Volumes/Dustling/Dustling.app") == .diskImage)
        #expect(location("/Applications/Dustling.app") == .applications)
        #expect(location("/Users/me/Downloads/Dustling.app") == .elsewhere)
    }

    @Test func currentDesignatedRequirementIsReadableInTests() {
        // Test hosts are signed at least ad hoc, so a requirement can be read.
        let requirement = CodeIdentity.currentDesignatedRequirement()
        #expect(requirement != nil)
        #expect(requirement?.isEmpty == false)
    }
}
