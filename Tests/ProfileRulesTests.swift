import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Covers the library-folder and name rules behind New Profile, Rename and
/// Change Folder. The gallery scan is fully recursive, so a library that sits
/// inside — or contains — another profile's library would leak that profile's
/// images in as a board; both directions must be refused, not just equality.
struct ProfileRulesTests {
    private let work = Profile(id: UUID(), name: "Work", libraryPath: "/Users/me/Pictures/Work")
    private let home = Profile(id: UUID(), name: "Home", libraryPath: "/Volumes/Archive/Home")

    // MARK: - Path relation

    @Test(arguments: [
        ("/a/lib", "/a/lib", LibraryPathRelation.same),
        ("/a/lib/sub", "/a/lib", .inside),
        ("/a/lib/sub/deeper", "/a/lib", .inside),
        ("/a", "/a/lib", .contains),
        ("/a/library", "/a/lib", .unrelated),
        ("/a/lib", "/a/library", .unrelated),
        ("/b/lib", "/a/lib", .unrelated),
    ])
    func relationComparesWholeComponents(candidate: String, other: String, expected: LibraryPathRelation) {
        #expect(ProfileRules.relation(of: candidate, to: other) == expected)
    }

    @Test func relationIgnoresTrailingSlashAndDotSegments() {
        #expect(ProfileRules.relation(of: "/a/lib/", to: "/a/lib") == .same)
        #expect(ProfileRules.relation(of: "/a/x/../lib/./sub", to: "/a/lib") == .inside)
    }

    /// APFS volumes are case-insensitive by default, so `/A/Lib` *is* `/a/lib`.
    @Test func relationIsCaseInsensitive() {
        #expect(ProfileRules.relation(of: "/Users/Me/PICTURES/work", to: "/Users/me/Pictures/Work") == .same)
    }

    @Test func relationExpandsTilde() {
        let home = NSHomeDirectory()
        #expect(ProfileRules.relation(of: "~/Lib", to: home + "/Lib") == .same)
    }

    @Test func rootContainsEverything() {
        #expect(ProfileRules.relation(of: "/", to: "/a/lib") == .contains)
    }

    // MARK: - Library validation

    @Test func emptyPathIsRefused() {
        #expect(ProfileRules.libraryProblem(path: "  ", profiles: [work], excluding: nil) == .empty)
    }

    @Test func relativePathIsRefused() {
        #expect(ProfileRules.libraryProblem(path: "Pictures/New", profiles: [work], excluding: nil) == .notAbsolute)
    }

    @Test func siblingFolderIsAccepted() {
        let problem = ProfileRules.libraryProblem(
            path: "/Users/me/Pictures/Personal", profiles: [work, home], excluding: nil
        )
        #expect(problem == nil)
    }

    @Test func sameFolderNamesTheOwningProfile() {
        let problem = ProfileRules.libraryProblem(
            path: "/users/me/pictures/work/", profiles: [home, work], excluding: nil
        )
        #expect(problem == .conflict(.same, profileName: "Work"))
    }

    @Test func folderInsideAnotherLibraryIsRefused() {
        let problem = ProfileRules.libraryProblem(
            path: "/Volumes/Archive/Home/2026", profiles: [work, home], excluding: nil
        )
        #expect(problem == .conflict(.inside, profileName: "Home"))
    }

    @Test func folderContainingAnotherLibraryIsRefused() {
        let problem = ProfileRules.libraryProblem(
            path: "/Users/me/Pictures", profiles: [work, home], excluding: nil
        )
        #expect(problem == .conflict(.contains, profileName: "Work"))
    }

    /// Change Folder re-validates the active profile; its own current folder
    /// (or a subfolder of it) must not count as a clash with itself.
    @Test func excludedProfileIsIgnored() {
        let problem = ProfileRules.libraryProblem(
            path: "/Users/me/Pictures/Work/Moved", profiles: [work, home], excluding: work.id
        )
        #expect(problem == nil)
    }

    /// A migrated profile whose folder was never chosen has an empty path; it
    /// must not "contain" every candidate.
    @Test func profilesWithoutAFolderAreSkipped() {
        let unset = Profile(id: UUID(), name: "Default", libraryPath: "")
        #expect(ProfileRules.libraryProblem(path: "/Users/me/New", profiles: [unset], excluding: nil) == nil)
    }

    // MARK: - Mounted volume

    /// Older builds created a missing library folder on the boot disk, so an
    /// unplugged drive can leave a real `/Volumes/<drive>/…` folder behind. A
    /// library under /Volumes only counts when its volume is mounted there.
    @Test(arguments: [
        ("/Volumes/Archive/Lib", "/Volumes/Archive", true),
        ("/Volumes/Archive/Lib", "/", false),
        ("/Volumes/Archive/Lib", "/System/Volumes/Data", false),
        ("/Users/me/Lib", "/", true),
        ("/Users/me/Lib", "/System/Volumes/Data", true),
    ])
    func libraryUnderVolumesNeedsItsDriveMounted(path: String, volume: String, expected: Bool) {
        #expect(ProfileRules.isOnExpectedVolume(path: path, volumePath: volume) == expected)
    }

    // MARK: - Name validation

    @Test func blankNameIsRefused() {
        #expect(ProfileRules.nameProblem(" \n", profiles: [work], excluding: nil) == .empty)
    }

    @Test func duplicateNameIsRefusedCaseInsensitively() {
        #expect(ProfileRules.nameProblem(" work ", profiles: [work, home], excluding: nil) == .duplicate("Work"))
    }

    @Test func renamingToADifferentCaseOfOwnNameIsAllowed() {
        #expect(ProfileRules.nameProblem("WORK", profiles: [work, home], excluding: work.id) == nil)
    }

    @Test func uniqueNameIsAccepted() {
        #expect(ProfileRules.nameProblem("Client X", profiles: [work, home], excluding: nil) == nil)
    }
}
