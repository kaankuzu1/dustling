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

    @Test func applicationsFolderOnAnotherDiskIsNotADiskImage() {
        func location(_ path: String, home: String = "/Users/me") -> RunningLocation {
            CodeIdentity.runningLocation(bundleURL: URL(filePath: path), home: URL(filePath: home))
        }
        #expect(location("/Volumes/External/Applications/Dustling.app") == .applications)
        #expect(location("/Volumes/External/Applications/Utilities/Dustling.app") == .applications)
        // A home folder on another disk: its Applications folder is the user's own.
        #expect(location("/Volumes/Home/me/Applications/Dustling.app", home: "/Volumes/Home/me") == .applications)
        #expect(location("/Users/me/Applications/Dustling.app") == .applications)
        // Anything else on a mounted volume is still treated as the disk image.
        #expect(location("/Volumes/Dustling 0.2.0/Dustling.app") == .diskImage)
        #expect(location("/Volumes/External/Downloads/Dustling.app") == .diskImage)
        #expect(location("/Volumes/Applications/Dustling.app") == .diskImage)
    }

    @Test func currentDesignatedRequirementIsReadableInTests() {
        // Test hosts are signed at least ad hoc, so a requirement can be read.
        let requirement = CodeIdentity.currentDesignatedRequirement()
        #expect(requirement != nil)
        #expect(requirement?.isEmpty == false)
    }
}
