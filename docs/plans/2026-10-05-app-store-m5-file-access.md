# App Store build, milestone 5: sandbox file access — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the sandboxed App Store build keeps access to every folder and file the person chooses, across relaunches:
- library folders, the models folder, custom model folders and LoRA files;
- source images from outside the library are copied into the profile;
- first run offers the person's Hugging Face cache and a Pictures default.

The Gemma first-use download (#18) moves out of the Scenario panel into an app-owned download with visible progress.

**Architecture:**
- **`FileAccess` is one protocol with two implementations.** Both compile in every build, and `BuildFlavor.isAppStore` picks one.
  - **`PassthroughFileAccess` (DMG):** uses every path as given.
  - **`SandboxFileAccess` (App Store):** remembers each folder or file chosen in an open panel as a security-scoped bookmark, in one path-keyed `GrantStore` (`grants.json`). It starts a grant only while a *lease* holds it.
  - **How a path is covered:** by the deepest grant at or above it. A LoRA downloaded into the models folder, or a source image in the library, needs nothing of its own.
- **Who holds leases:**
  - `ProfileStore` holds the active library's grant.
  - `AppSettings` holds the session-long folders: models, mflux cache, local model and Gemma folders.
  - `JobRunner` holds each job's LoRA files and local model for the job's run.
- **Every open panel that picks a folder or LoRA** goes through `GrantingPanel`, which records the grant.
- **Every source-image entry point** passes its path through `settings.adoptSourceImage(_:)`. That copies outside images into `Profiles/<id>/Inputs/<sha256>.<ext>` in the App Store build.
- **`ModelDownloadStore`** runs `hf download` for Gemma in a process the app owns. Panels wait on it and show its progress; closing a panel stops the wait, not the download.

**Tech stack:** Swift 5.9 (MainActor default isolation), SwiftUI, Swift Testing, XcodeGen.

**Spec:** `docs/specs/2026-10-03-app-store-build-design.md`. The relevant parts are §4 (sandbox file access), §1 (entitlements), §7 (tests and the manual checklist), the risk table, and milestone 5. Read the spec and this plan.

**Branch:** `feature/sandbox-file-access`, from `main` (at `3bf76c3` or later).

**Release:** none in this plan. After merge, the owner decides on a DMG release (v0.17.0 would carry the #18 change) and a TestFlight upload.

### Where this plan departs from the spec, and why

The owner reviews these before execution. Task 11 writes them into the spec.

1. **One path-keyed grant store, not bookmark fields.** The spec puts bookmarks in `Profile.libraryBookmark` and `LoraEntry.bookmark` fields; this plan uses one store, `grants.json`, keyed by path.
   - **Why:** jobs, drafts, saved stacks and settings all carry plain paths, and a LoRA can enter a job without a library entry. One lookup by path covers every one of them, and anything inside a granted folder needs nothing extra.
   - **Cost if wrong:** a folder renamed or moved in Finder isn't followed to its new name. It shows as missing until it's chosen again, which is what the DMG does today.
2. **The models-folder row stays in Settings ▸ Advanced,** where the Hugging Face home field is now, rather than Settings ▸ Models.
3. **Fields that also take a Hugging Face repo ID stay typeable:** model source overrides, the Gemma model and the params panel's custom model. Browse… grants access, and a typed folder the app can't open shows a hint. Only the pure folder fields become picker-only in the App Store build: the library, the models folder and the mflux cache.
4. **Pasted images also go to `Inputs/`,** like open-panel picks and drag and drop.
5. **#18 is fixed in part.**
   - **Done here:** the download runs outside the panel and shows progress, and the panel says "Loading model…".
   - **Left open:** hf-xet starting a new `.incomplete` instead of resuming one is upstream behavior. The PR says "Refs #18", and the issue stays open for it.

## Global Constraints

**Platform:** macOS 26.0, arm64 only. The bundle IDs are:
- DMG: `com.mlxbits.image-studio`
- App Store: `com.mlxbits.image-studio.appstore`

**App Store entitlements** (already in `Resources/MLXBits_Image_Studio_AppStore.entitlements`, unchanged here):
- `app-sandbox`
- `files.user-selected.read-write`
- `files.bookmarks.app-scope`
- `assets.pictures.read-write`
- `network.client`

**Copy, verbatim:**
- **Lost LoRA:** `Access to <file name> was lost — locate the file again.` (spec §4)
- **First run, cache found:** `We found your Hugging Face model cache — use it?` (spec §4)
- **Job failures:**
  - `No library folder chosen — choose one in Settings`
  - `Library folder not found: <path> — reconnect its drive or choose a folder in Settings`
  - `No access to the library folder <path> — choose it again in Settings`

**Default library for Skip for Now:**
- App Store: `<real home>/Pictures/MLXBits Image Studio`
- DMG: `<home>/MLXBits Image Studio`, as now

Inside the sandbox, `NSHomeDirectory()` is the app's container. Use `FileAccessPath.realHome` for the person's home.

**Process**

- **Lint gate before every commit.** CI runs exactly these:
  ```bash
  swiftformat --lint --config .swiftformat .
  swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict
  ```
  - `type_contents_order`: type properties, then type methods, then instance properties (stored and computed, `body` included), then `init`, then methods.
  - The `AppSettings.init` body is baselined at "92 lines". Don't add lines to it: new stored properties get default values instead.
  - `Views/Settings/SettingsView.swift` has no `file_length` exemption, so keep it under 500 lines.
  - Don't put `= nil` on optional `var`s (`implicit_optional_initialization`).
- **New Swift files:** run this, then commit `project.pbxproj`:
  ```bash
  xcodegen generate && git checkout -- "MLXBits Image Studio.xcodeproj/xcshareddata/xcschemes/MLXBits Image Studio.xcscheme"
  ```
- **Tests and builds** use their own derived-data folder, never Xcode's default, which belongs to the owner's running build.
  - **One test suite:**
    ```bash
    xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio" \
      -derivedDataPath "$TMPDIR/image-studio-m5-derived" test BUNDLE_PYTHON_RUNTIME=NO \
      -only-testing:"MLXBits Image StudioTests/<SuiteName>" 2>&1 | grep -E "✔|✘|passed|failed|error:" | tail -30
    ```
  - **The full suite** is the same command without `-only-testing`.
  - **App Store flavor, compile only:**
    ```bash
    xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio (App Store)" \
      -configuration Debug-AppStore -derivedDataPath "$TMPDIR/image-studio-m5-derived" \
      build BUNDLE_PYTHON_RUNTIME=NO CODE_SIGNING_ALLOWED=NO -quiet
    ```
- **Tests never touch real data:**
  - Tests that create `AppSettings()` call `settings.suspendPersistence()` before changing anything.
  - Never construct `LoraLibraryStore()` in a test: it reads and writes the real `lora-library.json`. Test its pure statics instead.
- **Data safety:**
  - App Store-scheme runs use their own container.
  - A DMG Debug build from this branch shares the owner's real App Support. Never launch one while the owner's copy is running.
- **Tests cover pure logic only:** Swift Testing, no UI tests (AGENTS.md). View-only steps are verified by building both flavors.
- **Commits:** no AI attribution of any kind.

## Review Focus

These are the failure modes most likely to reach a person using the app. Each has a pinning test in the task that owns the code.

- **External library drive unplugged, then plugged back in.** The banner says *not found*, not *no access*. When the drive returns, the grant restarts and the gallery rescans. Tests: Task 3 `aMissingFolderIsMissingEvenWithoutAccess`, Task 4 `regainedAccessIsPickedUpOnRefresh`.
- **The same picture brought in twice, or from two folders.** The profile's `Inputs/` keeps one copy. Test: Task 2 `theSameImageIsStoredOnce`.
- **A LoRA given as a Hugging Face repo ID or a ComfyUI server name.** It's never treated as a file, so it's never "lost". Tests: Task 2 `repoIDsAndEmptyPathsAreNotFiles`, Task 5 `repoIDsAreLeftOut`.
- **Offline, or the Hub down, with Gemma already downloaded.** The pre-download step doesn't block the run. Tests: Task 10 `localPathsAndOfflineModeNeedNoFetch`, `aFailedFetchWithACachedCopyStillRuns`.
- **A folder renamed or moved in Finder.** It isn't silently followed; it shows as missing, as in the DMG. Test: Task 2 `aMovedFolderIsNotFollowed`.

One more risk can't be pinned by a unit test: a LoRA grant that starts while the warm driver is already running (the spec's risk table). It is manual check 3 in Task 12.

---

### Task 1: Grant storage

**Files:**
- Create: `Utilities/FileAccessPath.swift`
- Create: `Utilities/GrantStore.swift`
- Test: `Tests/GrantStoreTests.swift`

**Interfaces:**
- Produces:
  - `FileAccessPath`:
    - `normalized(_:) -> String`
    - `isLocal(_:) -> Bool`
    - `isReadable(_:) -> Bool`
    - `realHome: String`
  - `struct Grant: Equatable { path: String; bookmark: Data }`
  - `struct BookmarkCodec { make: (URL) throws -> Data; resolve: (Data) throws -> (url: URL, isStale: Bool) }`, with `static let securityScoped`
  - `final class GrantStore`:
    - `init(url:)`
    - `bookmarks: [String: Data]` (read-only)
    - `set(_:for:)`, `remove(_:)`
    - `grant(covering:) -> Grant?`

- [ ] **Step 1: Write the failing test**

`Tests/GrantStoreTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The remembered folder and file grants (spec §4), kept in `grants.json` and
/// looked up by path: a grant covers its own path and everything inside it.
struct GrantStoreTests {
    private let root = FakeRuntime.tempDirectory("GrantStoreTests")

    private var storeURL: URL {
        root.appendingPathComponent("grants.json")
    }

    @Test func grantsSurviveARelaunch() {
        GrantStore(url: storeURL).set(Data([1, 2, 3]), for: "/Volumes/Models/hf")
        #expect(GrantStore(url: storeURL).bookmarks["/Volumes/Models/hf"] == Data([1, 2, 3]))
    }

    @Test func theDeepestGrantCoversAPath() {
        let store = GrantStore(url: storeURL)
        store.set(Data([1]), for: "/Users/me/models")
        store.set(Data([2]), for: "/Users/me/models/loras")
        #expect(store.grant(covering: "/Users/me/models/loras/style.safetensors")?.path == "/Users/me/models/loras")
        #expect(store.grant(covering: "/Users/me/models/hub/x")?.path == "/Users/me/models")
        #expect(store.grant(covering: "/Users/me/models")?.bookmark == Data([1]))
    }

    @Test func aSiblingWithTheSamePrefixIsNotCovered() {
        let store = GrantStore(url: storeURL)
        store.set(Data([1]), for: "/a/lib")
        #expect(store.grant(covering: "/a/library/x.png") == nil)
    }

    @Test func forgettingRemovesTheGrant() {
        let store = GrantStore(url: storeURL)
        store.set(Data([1]), for: "/a/lib")
        store.remove("/a/lib")
        #expect(GrantStore(url: storeURL).grant(covering: "/a/lib/x") == nil)
    }

    @Test func pathsHaveOneNormalForm() {
        #expect(FileAccessPath.normalized("/a/b/../lib/") == "/a/lib")
        #expect(FileAccessPath.isLocal("/x") && FileAccessPath.isLocal("~/x"))
        #expect(!FileAccessPath.isLocal("org/repo") && !FileAccessPath.isLocal(""))
    }

    @Test func readabilityIsAnOpenNotAStat() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(FileAccessPath.isReadable(root.path))
        #expect(!FileAccessPath.isReadable(root.appendingPathComponent("missing").path))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run the one-suite command from Global Constraints with `GrantStoreTests`.
Expected: build failure, `cannot find 'GrantStore' in scope`. The new test file needs `xcodegen generate` first; restore the scheme as Global Constraints says.

- [ ] **Step 3: Write `Utilities/FileAccessPath.swift`**

```swift
import Foundation

/// Path helpers for sandbox file access (spec §4).
nonisolated enum FileAccessPath {
    /// The person's real home folder. Inside the sandbox `NSHomeDirectory()`
    /// is the app's container, which is never what a folder default means.
    static var realHome: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    /// The form grants are stored and looked up under: `~` expanded, `.`/`..`
    /// folded, symlinks resolved. One folder always has one key.
    static func normalized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Whether `path` names a place on disk rather than a Hugging Face repo ID,
    /// a ComfyUI server LoRA name, or nothing.
    static func isLocal(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~")
    }

    /// Whether this process can open `path` for reading now. The sandbox lets
    /// the app `stat` a folder it has no grant for, but not open it.
    static func isReadable(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}
```

- [ ] **Step 4: Write `Utilities/GrantStore.swift`**

```swift
import Foundation

/// One remembered grant: the normalized path it was made for, and its bookmark.
struct Grant: Equatable {
    let path: String
    let bookmark: Data
}

/// Makes and resolves the bookmark data a grant is kept as. Security-scoped in
/// the app. It works outside the sandbox too, so tests use it as-is; one test
/// wraps it to fake a stale bookmark.
struct BookmarkCodec {
    static let securityScoped = Self(
        make: { url in
            try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolve: { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        }
    )

    var make: (URL) throws -> Data
    var resolve: (Data) throws -> (url: URL, isStale: Bool)
}

/// The App Store build's remembered grants (`grants.json` in App Support):
/// bookmark data keyed by the normalized path it was made for. One store for
/// every kind of grant — library, models folder, LoRA file — because jobs,
/// drafts, stacks and settings all carry plain paths (spec §4, as decided in
/// milestone 5).
final class GrantStore {
    private(set) var bookmarks: [String: Data]
    private let url: URL

    init(url: URL) {
        self.url = url
        bookmarks = (try? JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url))) ?? [:]
    }

    func set(_ bookmark: Data, for path: String) {
        bookmarks[path] = bookmark
        save()
    }

    func remove(_ path: String) {
        guard bookmarks.removeValue(forKey: path) != nil else { return }
        save()
    }

    /// The deepest grant for `path` or a folder above it. `path` must already
    /// be ``FileAccessPath/normalized(_:)``.
    func grant(covering path: String) -> Grant? {
        var candidate = path
        while true {
            if let bookmark = bookmarks[candidate] {
                return Grant(path: candidate, bookmark: bookmark)
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != candidate else { return nil }
            candidate = parent
        }
    }

    /// A failed write loses only this launch's new grants; the next choice
    /// writes the file again.
    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(bookmarks).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run `xcodegen generate` (and restore the scheme), then the one-suite command with `GrantStoreTests`.
Expected: 6 tests pass.

- [ ] **Step 6: Lint and commit**

```bash
git checkout -b feature/sandbox-file-access
git add docs/plans/2026-10-05-app-store-m5-file-access.md Utilities/FileAccessPath.swift Utilities/GrantStore.swift \
  Tests/GrantStoreTests.swift "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: grant store for sandbox file access"
```

---

### Task 2: `FileAccess` and its two implementations

**Files:**
- Create: `Utilities/FileAccess.swift`: the protocol, `FileAccessLease`, `FileAccessError`, `PassthroughFileAccess` and `FileAccessFactory`
- Create: `Utilities/SandboxFileAccess.swift`
- Create: `Utilities/SourceImageImport.swift`
- Create: `Tests/Support/RecordingFileAccess.swift`
- Test: `Tests/FileAccessTests.swift`, `Tests/SourceImageImportTests.swift`

**Interfaces:**
- Consumes: Task 1's `GrantStore`, `Grant`, `BookmarkCodec` and `FileAccessPath`.
- Produces:
  - `protocol FileAccess: AnyObject`:
    - `remember(_ url: URL)`, `forget(_ path: String)`
    - `canReach(_ path: String) -> Bool`
    - `beginAccess(to paths: [String]) throws -> FileAccessLease`
    - `beginAccess(toAvailable paths: [String]) -> FileAccessLease`
    - `adoptSourceImage(_ path: String, library: String, inputs: URL?) -> String`
  - `final class FileAccessLease`: `init(onEnd:)`, `end()`. Ending twice is harmless.
  - `enum FileAccessError: LocalizedError, Equatable { case accessLost(String) }`
  - `PassthroughFileAccess()`
  - `SandboxFileAccess(storeURL:codec:)`, plus `startedGrantPaths: [String]` for tests
  - `FileAccessFactory.make() -> any FileAccess`
  - `SourceImageImport.adopt(_:library:inputs:) throws -> String`
  - For tests: `RecordingFileAccess` with `unreachable`, `remembered`, `forgotten` and `isHeld(_:)`

- [ ] **Step 1: Write the failing tests**

`Tests/FileAccessTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// The two FileAccess implementations (spec §4, §7). The DMG passes every path
/// through. The App Store one keeps security-scoped bookmarks and starts them
/// while a lease holds them. Bookmarks resolve outside the sandbox too, so the
/// sandbox implementation runs here as it does in the app.
final class FileAccessTests {
    private let root: URL
    private let folder: URL
    private let lora: URL

    init() throws {
        root = FakeRuntime.tempDirectory("FileAccessTests")
        folder = root.appendingPathComponent("Chosen", isDirectory: true)
        lora = folder.appendingPathComponent("style.safetensors")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: lora)
    }

    private func sandbox(codec: BookmarkCodec = .securityScoped) -> SandboxFileAccess {
        SandboxFileAccess(storeURL: root.appendingPathComponent("grants.json"), codec: codec)
    }

    @Test func theDMGPassesEverythingThrough() throws {
        let access = PassthroughFileAccess()
        #expect(access.canReach("/no/such/file"))
        try access.beginAccess(to: ["/no/such/file"]).end()
        #expect(access.adoptSourceImage("/elsewhere/a.png", library: "/lib", inputs: root) == "/elsewhere/a.png")
    }

    @Test func aRememberedFolderCoversTheFilesInIt() throws {
        let access = sandbox()
        access.remember(folder)
        let lease = try access.beginAccess(to: [lora.path])
        #expect(access.startedGrantPaths == [FileAccessPath.normalized(folder.path)])
        lease.end()
        #expect(access.startedGrantPaths.isEmpty)
    }

    @Test func overlappingLeasesShareOneStartedGrant() throws {
        let access = sandbox()
        access.remember(folder)
        let first = try access.beginAccess(to: [lora.path])
        let second = try access.beginAccess(to: [folder.path])
        first.end()
        first.end() // ending twice is harmless
        #expect(access.startedGrantPaths.count == 1)
        second.end()
        #expect(access.startedGrantPaths.isEmpty)
    }

    @Test func aDeletedFileIsReportedAsLost() throws {
        let access = sandbox()
        access.remember(lora)
        try FileManager.default.removeItem(at: lora)
        #expect(!access.canReach(lora.path))
        #expect(throws: FileAccessError.accessLost(lora.path)) {
            try access.beginAccess(to: [lora.path])
        }
        #expect(FileAccessError.accessLost(lora.path).localizedDescription
            == "Access to style.safetensors was lost — locate the file again.")
    }

    @Test func repoIDsAndEmptyPathsAreNotFiles() throws {
        let access = sandbox()
        let lease = try access.beginAccess(to: ["org/some-lora", "", "server-lora.safetensors"])
        #expect(access.startedGrantPaths.isEmpty)
        lease.end()
    }

    @Test func sessionAccessSkipsWhatItCantReach() {
        let access = sandbox()
        access.remember(folder)
        let lease = access.beginAccess(toAvailable: [folder.path, root.appendingPathComponent("gone").path])
        #expect(access.startedGrantPaths.count == 1)
        lease.end()
    }

    /// A moved folder isn't followed: the grant resolves somewhere else now, so
    /// the old path counts as gone — what the DMG would see too.
    @Test func aMovedFolderIsNotFollowed() throws {
        let access = sandbox()
        access.remember(folder)
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Moved", isDirectory: true))
        #expect(!access.canReach(lora.path))
        #expect(throws: FileAccessError.self) {
            try access.beginAccess(to: [lora.path])
        }
    }

    @Test func aStaleBookmarkIsRecreated() throws {
        var made = 0
        let real = BookmarkCodec.securityScoped
        let codec = BookmarkCodec(
            make: { url in
                made += 1
                return try real.make(url)
            },
            resolve: { data in (try real.resolve(data).url, true) }
        )
        let access = sandbox(codec: codec)
        access.remember(folder)
        try access.beginAccess(to: [lora.path]).end()
        #expect(made == 2)
    }

    @Test func aForgottenGrantIsNotUsed() throws {
        let access = sandbox()
        access.remember(folder)
        access.forget(folder.path)
        let lease = try access.beginAccess(to: [lora.path])
        #expect(access.startedGrantPaths.isEmpty)
        lease.end()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
```

`Tests/SourceImageImportTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Source images from outside the library are copied into the profile's
/// `Inputs/` folder in the App Store build (spec §4), so re-runs and templates
/// keep working after a relaunch. Images already in the library stay in place.
struct SourceImageImportTests {
    private let root = FakeRuntime.tempDirectory("SourceImageImportTests")

    private var library: URL {
        root.appendingPathComponent("Library", isDirectory: true)
    }

    private var inputs: URL {
        root.appendingPathComponent("Profiles/P/Inputs", isDirectory: true)
    }

    private func image(_ name: String, in dir: URL, bytes: String = "png-bytes") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    @Test func anImageInTheLibraryIsUsedInPlace() throws {
        let inLibrary = try image("a.png", in: library.appendingPathComponent("Board", isDirectory: true))
        #expect(try SourceImageImport.adopt(inLibrary.path, library: library.path, inputs: inputs) == inLibrary.path)
        #expect(!FileManager.default.fileExists(atPath: inputs.path))
    }

    @Test func anImageFromElsewhereIsCopiedIntoInputs() throws {
        let outside = try image("Photo.PNG", in: root.appendingPathComponent("Downloads", isDirectory: true))
        let adopted = try SourceImageImport.adopt(outside.path, library: library.path, inputs: inputs)
        #expect(URL(fileURLWithPath: adopted).deletingLastPathComponent().path == inputs.path)
        #expect(adopted.hasSuffix(".png"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: adopted)) == Data("png-bytes".utf8))
    }

    @Test func theSameImageIsStoredOnce() throws {
        let one = try image("a.png", in: root.appendingPathComponent("X", isDirectory: true))
        let two = try image("b.png", in: root.appendingPathComponent("Y", isDirectory: true))
        let first = try SourceImageImport.adopt(one.path, library: library.path, inputs: inputs)
        let second = try SourceImageImport.adopt(two.path, library: library.path, inputs: inputs)
        #expect(first == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inputs.path).count == 1)
    }

    @Test func anImageAlreadyInInputsIsUsedInPlace() throws {
        let outside = try image("a.png", in: root.appendingPathComponent("X", isDirectory: true))
        let adopted = try SourceImageImport.adopt(outside.path, library: library.path, inputs: inputs)
        #expect(try SourceImageImport.adopt(adopted, library: library.path, inputs: inputs) == adopted)
    }

    @Test func theSandboxAdoptsAndTheDMGDoesNot() throws {
        let outside = try image("a.png", in: root.appendingPathComponent("X", isDirectory: true))
        let sandbox = SandboxFileAccess(storeURL: root.appendingPathComponent("grants.json"))
        #expect(sandbox.adoptSourceImage(outside.path, library: library.path, inputs: inputs) != outside.path)
        #expect(PassthroughFileAccess().adoptSourceImage(outside.path, library: library.path, inputs: inputs)
            == outside.path)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run `xcodegen generate` (and restore the scheme), then run `FileAccessTests` and `SourceImageImportTests` (two `-only-testing` flags).
Expected: build failure, `cannot find 'SandboxFileAccess' in scope`.

- [ ] **Step 3: Write `Utilities/FileAccess.swift`**

```swift
import Foundation

/// How the app reaches folders and files outside its own (spec §4). The DMG
/// passes every path through. The App Store build keeps a security-scoped grant
/// for each folder or file the person chooses, and starts it while a lease
/// holds it. Both compile in every build; ``FileAccessFactory`` picks one.
protocol FileAccess: AnyObject {
    /// Remembers access to a folder or file the person just chose in an open panel.
    func remember(_ url: URL)
    /// Drops the grant for `path` (a removed profile's library).
    func forget(_ path: String)
    /// Whether the app can open `path` now. Always true in the DMG.
    func canReach(_ path: String) -> Bool
    /// Holds every local path in `paths` open for one job or run. Repo IDs,
    /// server names and empty strings are skipped. Throws
    /// ``FileAccessError/accessLost(_:)`` for the first path it can't reach.
    func beginAccess(to paths: [String]) throws -> FileAccessLease
    /// Like ``beginAccess(to:)``, for folders held all session: anything it
    /// can't reach is skipped, and that folder's own row or banner says so.
    func beginAccess(toAvailable paths: [String]) -> FileAccessLease
    /// The path a source image should be used from: in place when it's inside
    /// `library`; otherwise, in the App Store build, a copy in `inputs`, so a
    /// re-run still finds it after a relaunch.
    func adoptSourceImage(_ path: String, library: String, inputs: URL?) -> String
}

/// Holds grants started by ``FileAccess/beginAccess(to:)`` until ``end()``.
/// Ending twice is harmless; a lease never ended keeps its grants for the session.
final class FileAccessLease {
    private var onEnd: (() -> Void)?

    init(onEnd: (() -> Void)? = nil) {
        self.onEnd = onEnd
    }

    func end() {
        let action = onEnd
        onEnd = nil
        action?()
    }
}

enum FileAccessError: LocalizedError, Equatable {
    /// A file or folder the app had access to is gone, or its grant no longer resolves.
    case accessLost(String)

    var errorDescription: String? {
        switch self {
        case let .accessLost(path):
            "Access to \(URL(fileURLWithPath: path).lastPathComponent) was lost — locate the file again."
        }
    }
}

/// The DMG's ``FileAccess``: the app isn't sandboxed, so every path is used as given.
final class PassthroughFileAccess: FileAccess {
    func remember(_: URL) {}

    func forget(_: String) {}

    func canReach(_: String) -> Bool {
        true
    }

    func beginAccess(to _: [String]) throws -> FileAccessLease {
        FileAccessLease()
    }

    func beginAccess(toAvailable _: [String]) -> FileAccessLease {
        FileAccessLease()
    }

    func adoptSourceImage(_ path: String, library _: String, inputs _: URL?) -> String {
        path
    }
}

enum FileAccessFactory {
    /// This flavor's FileAccess. The App Store one keeps its grants in App
    /// Support's `grants.json`, inside the container.
    static func make() -> any FileAccess {
        BuildFlavor.isAppStore
            ? SandboxFileAccess(storeURL: AppSettings.appSupportURL.appendingPathComponent("grants.json"))
            : PassthroughFileAccess()
    }
}
```

- [ ] **Step 4: Write `Utilities/SandboxFileAccess.swift`**

```swift
import Foundation

/// The App Store build's ``FileAccess`` (spec §4).
///
/// A folder or file chosen in an open panel is remembered as a security-scoped
/// bookmark in a ``GrantStore``. A path is reachable through the deepest grant
/// at or above it. Grants are started on demand and reference-counted, so
/// overlapping leases share one start. A stale bookmark is re-created quietly.
/// A bookmark that no longer resolves to the path it was made for (the file was
/// deleted, or the folder moved) isn't used.
final class SandboxFileAccess: FileAccess {
    private struct Started {
        let url: URL
        var count: Int
    }

    private enum Outcome {
        case started(String)
        /// No grant needed: the app's container, or Pictures (its entitlement).
        case notNeeded
        case lost
    }

    private let store: GrantStore
    private let codec: BookmarkCodec
    private var started: [String: Started] = [:]

    /// The grants started right now, by the path each was made for. For tests.
    var startedGrantPaths: [String] {
        started.keys.sorted()
    }

    init(storeURL: URL, codec: BookmarkCodec = .securityScoped) {
        store = GrantStore(url: storeURL)
        self.codec = codec
    }

    func remember(_ url: URL) {
        guard let bookmark = try? codec.make(url) else { return }
        store.set(bookmark, for: FileAccessPath.normalized(url.path))
    }

    func forget(_ path: String) {
        store.remove(FileAccessPath.normalized(path))
    }

    func canReach(_ path: String) -> Bool {
        guard FileAccessPath.isLocal(path) else { return false }
        let normalized = FileAccessPath.normalized(path)
        guard FileManager.default.fileExists(atPath: normalized) else { return false }
        return store.grant(covering: normalized) != nil || FileAccessPath.isReadable(normalized)
    }

    func beginAccess(to paths: [String]) throws -> FileAccessLease {
        var keys: [String] = []
        for path in paths where FileAccessPath.isLocal(path) {
            switch start(path) {
            case let .started(key):
                keys.append(key)
            case .notNeeded:
                break
            case .lost:
                keys.forEach(stop)
                throw FileAccessError.accessLost(path)
            }
        }
        return lease(for: keys)
    }

    func beginAccess(toAvailable paths: [String]) -> FileAccessLease {
        var keys: [String] = []
        for path in paths where FileAccessPath.isLocal(path) {
            if case let .started(key) = start(path) {
                keys.append(key)
            }
        }
        return lease(for: keys)
    }

    func adoptSourceImage(_ path: String, library: String, inputs: URL?) -> String {
        guard let inputs, FileAccessPath.isLocal(path) else { return path }
        return (try? SourceImageImport.adopt(path, library: library, inputs: inputs)) ?? path
    }

    private func lease(for keys: [String]) -> FileAccessLease {
        FileAccessLease { [weak self] in
            keys.forEach { self?.stop($0) }
        }
    }

    private func start(_ path: String) -> Outcome {
        let normalized = FileAccessPath.normalized(path)
        if let grant = store.grant(covering: normalized) {
            if started[grant.path] != nil {
                started[grant.path]?.count += 1
                return .started(grant.path)
            }
            if let resolved = try? codec.resolve(grant.bookmark),
               FileAccessPath.normalized(resolved.url.path) == grant.path,
               resolved.url.startAccessingSecurityScopedResource() {
                // Re-created while accessing, as a stale security-scoped bookmark requires.
                if resolved.isStale, let fresh = try? codec.make(resolved.url) {
                    store.set(fresh, for: grant.path)
                }
                started[grant.path] = Started(url: resolved.url, count: 1)
                return .started(grant.path)
            }
        }
        let reachable = FileManager.default.fileExists(atPath: normalized) && FileAccessPath.isReadable(normalized)
        return reachable ? .notNeeded : .lost
    }

    private func stop(_ key: String) {
        guard var entry = started[key] else { return }
        entry.count -= 1
        if entry.count > 0 {
            started[key] = entry
        } else {
            entry.url.stopAccessingSecurityScopedResource()
            started[key] = nil
        }
    }
}
```

- [ ] **Step 5: Write `Utilities/SourceImageImport.swift`**

```swift
import CryptoKit
import Foundation

/// Copies a source image from outside the library into a profile's `Inputs/`
/// folder (spec §4). The copy is named by a hash of its contents, so an image
/// brought in twice is kept once.
enum SourceImageImport {
    static func adopt(_ path: String, library: String, inputs: URL) throws -> String {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        if isInside(source.path, library) || isInside(source.path, inputs.path) {
            return path
        }
        let data = try Data(contentsOf: source)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = source.pathExtension.lowercased()
        let copy = inputs.appendingPathComponent(ext.isEmpty ? hash : "\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            try data.write(to: copy, options: .atomic)
        }
        return copy.path
    }

    private static func isInside(_ path: String, _ folder: String) -> Bool {
        guard !folder.isEmpty else { return false }
        let relation = ProfileRules.relation(of: path, to: folder)
        return relation == .inside || relation == .same
    }
}
```

- [ ] **Step 6: Write `Tests/Support/RecordingFileAccess.swift`**

Later tasks use it to check what their callers ask for.

```swift
import Foundation
@testable import MLXBits_Image_Studio

/// A FileAccess that records what the app asks of it, for tests of the callers:
/// ProfileStore, AppSettings. Paths in ``unreachable`` can't be reached.
final class RecordingFileAccess: FileAccess {
    var unreachable: Set<String> = []
    private(set) var remembered: [String] = []
    private(set) var forgotten: [String] = []
    /// How many unended leases hold each path.
    private var held: [String: Int] = [:]

    func isHeld(_ path: String) -> Bool {
        (held[path] ?? 0) > 0
    }

    func remember(_ url: URL) {
        remembered.append(url.path)
    }

    func forget(_ path: String) {
        forgotten.append(path)
    }

    func canReach(_ path: String) -> Bool {
        !unreachable.contains(path)
    }

    func beginAccess(to paths: [String]) throws -> FileAccessLease {
        if let lost = paths.first(where: { unreachable.contains($0) }) {
            throw FileAccessError.accessLost(lost)
        }
        return hold(paths)
    }

    func beginAccess(toAvailable paths: [String]) -> FileAccessLease {
        hold(paths.filter { !unreachable.contains($0) })
    }

    func adoptSourceImage(_ path: String, library _: String, inputs _: URL?) -> String {
        path
    }

    private func hold(_ paths: [String]) -> FileAccessLease {
        let kept = paths.filter(FileAccessPath.isLocal)
        kept.forEach { held[$0, default: 0] += 1 }
        return FileAccessLease { [weak self] in
            kept.forEach { self?.held[$0, default: 1] -= 1 }
        }
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run `xcodegen generate` (and restore the scheme), then `FileAccessTests` and `SourceImageImportTests`.
Expected: 14 tests pass.

If `aRememberedFolderCoversTheFilesInIt` fails because `startAccessingSecurityScopedResource()` returned false in the test host, stop. Bookmarks resolved and started unsandboxed on this Mac on 2026-10-05 (a `swiftc` probe printed `start true`), so a failure here means something changed. Investigate before working around it.

- [ ] **Step 8: Lint and commit**

```bash
git add Utilities/FileAccess.swift Utilities/SandboxFileAccess.swift Utilities/SourceImageImport.swift \
  Tests/Support/RecordingFileAccess.swift Tests/FileAccessTests.swift Tests/SourceImageImportTests.swift \
  "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: FileAccess with passthrough and sandbox implementations"
```

---

### Task 3: AppSettings holds the session folders; `LibraryStatus`

**Files:**
- Create: `Models/LibraryStatus.swift`
- Create: `Stores/AppSettings+FileAccess.swift`
- Modify: `Stores/AppSettings.swift`:
  - the `didSet` of `hfHome`, `mfluxCacheDir`, `gemmaModelPath`, `ideogram4ModelRepoOverride` and `modelDefaults`
  - two new stored properties
  - `profileFileURL` becomes `private(set)`
- Modify: `App/MLXBitsImageStudioApp.swift` (`init`)
- Test: `Tests/AppSettingsFileAccessTests.swift`, `Tests/LibraryStatusTests.swift`

**Interfaces:**
- Consumes: Task 2's `FileAccess`, `FileAccessLease`, `FileAccessFactory`, `SandboxFileAccess` and `RecordingFileAccess`.
- Produces:
  - `AppSettings`:
    - `var fileAccess: any FileAccess` (settable, for tests)
    - `var sessionLease: FileAccessLease?`
    - `sessionAccessPaths: [String]`, `refreshSessionAccess()`
    - `inputsDirectory: URL?`, `adoptSourceImage(_:) -> String`
    - `libraryStatus: LibraryStatus`
  - `enum LibraryStatus { unset, available, missing, noAccess }`, with `init(path:exists:reachable:)` and `jobFailureReason(path:) -> String?`

- [ ] **Step 1: Write the failing tests**

`Tests/LibraryStatusTests.swift`:

```swift
@testable import MLXBits_Image_Studio
import Testing

/// Whether the active library can take images: drives the missing-library
/// banner and the job guard (spec §4: a library without a grant shows the banner).
struct LibraryStatusTests {
    @Test func noFolderIsUnset() {
        #expect(LibraryStatus(path: "", exists: false, reachable: true) == .unset)
    }

    @Test func aMissingFolderIsMissingEvenWithoutAccess() {
        #expect(LibraryStatus(path: "/L", exists: false, reachable: false) == .missing)
    }

    @Test func aFolderWithoutAGrantNeedsAccess() {
        #expect(LibraryStatus(path: "/L", exists: true, reachable: false) == .noAccess)
        #expect(LibraryStatus(path: "/L", exists: true, reachable: true) == .available)
    }

    @Test func jobsFailWithAReasonUnlessAvailable() {
        #expect(LibraryStatus.available.jobFailureReason(path: "/L") == nil)
        #expect(LibraryStatus.unset.jobFailureReason(path: "") == "No library folder chosen — choose one in Settings")
        #expect(LibraryStatus.missing.jobFailureReason(path: "/L")
            == "Library folder not found: /L — reconnect its drive or choose a folder in Settings")
        #expect(LibraryStatus.noAccess.jobFailureReason(path: "/L")
            == "No access to the library folder /L — choose it again in Settings")
    }
}
```

`Tests/AppSettingsFileAccessTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// AppSettings holds its folder settings open for the session (the models
/// folder, the mflux cache, local model and Gemma folders), and copies outside
/// source images into the active profile's Inputs/ (spec §4).
struct AppSettingsFileAccessTests {
    private func settings(_ access: any FileAccess) -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.fileAccess = access
        return settings
    }

    @Test func choosingAModelsFolderHoldsItAndLetsTheOldOneGo() {
        let access = RecordingFileAccess()
        let s = settings(access)
        s.hfHome = "/Volumes/Models/hf"
        #expect(access.isHeld("/Volumes/Models/hf"))
        s.hfHome = "/Volumes/Other/hf"
        #expect(access.isHeld("/Volumes/Other/hf"))
        #expect(!access.isHeld("/Volumes/Models/hf"))
    }

    @Test func localModelFoldersAreHeldAndRepoIDsAreNot() {
        let access = RecordingFileAccess()
        let s = settings(access)
        var defaults = s.defaults(for: .flux2Klein9B)
        defaults.modelRepoOverride = "/Volumes/Models/klein"
        s.updateDefaults(defaults, for: .flux2Klein9B)
        s.mfluxCacheDir = "/Volumes/Models/mflux"
        s.gemmaModelPath = "mlx-community/gemma-3-12b-it-4bit"
        #expect(access.isHeld("/Volumes/Models/klein"))
        #expect(access.isHeld("/Volumes/Models/mflux"))
        #expect(!access.isHeld("mlx-community/gemma-3-12b-it-4bit"))
    }

    @Test func sourceImagesLandInTheActiveProfilesInputs() throws {
        let root = FakeRuntime.tempDirectory("AppSettingsFileAccessTests")
        let s = settings(SandboxFileAccess(storeURL: root.appendingPathComponent("grants.json")))
        s.activateProfile(
            contentURL: root.appendingPathComponent("Profiles/P/profile.json"),
            libraryPath: root.appendingPathComponent("Library").path
        )
        let outside = root.appendingPathComponent("Downloads/a.png")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: outside)

        #expect(s.inputsDirectory?.path == root.appendingPathComponent("Profiles/P/Inputs").path)
        #expect(s.adoptSourceImage(outside.path).hasPrefix(root.appendingPathComponent("Profiles/P/Inputs").path))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run `xcodegen generate` (and restore the scheme), then `LibraryStatusTests` and `AppSettingsFileAccessTests`.
Expected: build failure, `cannot find 'LibraryStatus' in scope` and `value of type 'AppSettings' has no member 'fileAccess'`.

- [ ] **Step 3: Write `Models/LibraryStatus.swift`**

```swift
/// Whether the active profile's library folder can take new images (spec §4).
enum LibraryStatus: Equatable {
    /// No folder chosen yet; the first-run prompt is up.
    case unset
    case available
    /// The folder isn't there: an unplugged drive, or moved in Finder.
    case missing
    /// App Store build: the folder is there, but the app has no grant for it.
    /// It was chosen by an older build, or its bookmark stopped resolving.
    /// Choosing it again re-grants.
    case noAccess

    init(path: String, exists: Bool, reachable: Bool) {
        if path.isEmpty {
            self = .unset
        } else if !exists {
            self = .missing
        } else if !reachable {
            self = .noAccess
        } else {
            self = .available
        }
    }

    /// Why a generation can't save into the library, or nil when it can.
    func jobFailureReason(path: String) -> String? {
        switch self {
        case .available: nil
        case .unset: "No library folder chosen — choose one in Settings"
        case .missing: "Library folder not found: \(path) — reconnect its drive or choose a folder in Settings"
        case .noAccess: "No access to the library folder \(path) — choose it again in Settings"
        }
    }
}
```

- [ ] **Step 4: Add the stored properties to `Stores/AppSettings.swift`**

Directly after `@ObservationIgnored private let saveDebouncer = Debouncer()`, add:

```swift
    /// How the app reaches folders and files outside its own (spec §4): paths
    /// pass through in the DMG; the App Store build keeps security-scoped
    /// grants. Settable so tests can swap in a recording one.
    @ObservationIgnored var fileAccess: any FileAccess = FileAccessFactory.make()
    /// Holds the folder settings' grants for the session; see ``refreshSessionAccess()``.
    @ObservationIgnored var sessionLease: FileAccessLease?
```

Change `@ObservationIgnored private var profileFileURL: URL?` to `@ObservationIgnored private(set) var profileFileURL: URL?`.

Give each of these five properties the same new `didSet`: `hfHome`, `mfluxCacheDir`, `gemmaModelPath`, `ideogram4ModelRepoOverride` and `modelDefaults`. Their current body is `didSet { save() }`; replace it with:

```swift
        didSet {
            save()
            refreshSessionAccess()
        }
```

Don't touch `init`: its body length is baselined.

- [ ] **Step 5: Write `Stores/AppSettings+FileAccess.swift`**

```swift
import Foundation

/// AppSettings' part in sandbox file access (spec §4).
extension AppSettings {
    /// The folders read all session long: the models folder, the mflux cache,
    /// and any local model or Gemma folder. Repo IDs and empty settings drop out
    /// in ``FileAccess``.
    var sessionAccessPaths: [String] {
        [hfHome, mfluxCacheDir, gemmaModelPath, ideogram4ModelRepoOverride ?? ""]
            + modelDefaults.values.compactMap(\.modelRepoOverride)
    }

    /// The active profile's `Inputs/` folder, where source images from outside
    /// the library are copied.
    var inputsDirectory: URL? {
        profileFileURL?.deletingLastPathComponent().appendingPathComponent("Inputs", isDirectory: true)
    }

    /// Whether the active library can take new images.
    var libraryStatus: LibraryStatus {
        LibraryStatus(path: outputDir, exists: libraryRootExists(), reachable: fileAccess.canReach(outputDir))
    }

    /// Re-holds ``sessionAccessPaths`` after one changes. The new lease starts
    /// before the old one ends, so a folder in both is never dropped in between.
    func refreshSessionAccess() {
        let next = fileAccess.beginAccess(toAvailable: sessionAccessPaths)
        sessionLease?.end()
        sessionLease = next
    }

    /// The path a source image should be used from: in place when it's in the
    /// library; otherwise, in the App Store build, a copy in ``inputsDirectory``.
    func adoptSourceImage(_ path: String) -> String {
        fileAccess.adoptSourceImage(path, library: outputDir, inputs: inputsDirectory)
    }
}
```

- [ ] **Step 6: Hold the session folders from launch**

In `App/MLXBitsImageStudioApp.swift` `init()`, directly after the `if testHost { settings.suspendPersistence() }` block, add:

```swift
        // The models folder and other folder settings stay reachable all
        // session (spec §4). didSet doesn't run for init's own assignments.
        settings.refreshSessionAccess()
```

- [ ] **Step 7: Run the tests to verify they pass**

Run `xcodegen generate` (and restore the scheme), then `LibraryStatusTests` and `AppSettingsFileAccessTests`.
Expected: 7 tests pass. Then run the full suite. Expected: all pass.

- [ ] **Step 8: Lint and commit**

```bash
git add Models/LibraryStatus.swift Stores/AppSettings.swift "Stores/AppSettings+FileAccess.swift" \
  App/MLXBitsImageStudioApp.swift Tests/LibraryStatusTests.swift Tests/AppSettingsFileAccessTests.swift \
  "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: AppSettings holds folder grants for the session"
```

---

### Task 4: ProfileStore holds the active library's grant

**Files:**
- Modify: `Stores/ProfileStore.swift`
- Modify: `Views/Profiles/MissingLibraryBanner.swift` (text only)
- Modify: `Views/Settings/SettingsView.swift` (the library section's warning label)
- Test: `Tests/ProfileStoreTests.swift` (helpers gain an `access:` parameter; four new tests)

**Interfaces:**
- Consumes: Task 3's `settings.fileAccess`, `settings.libraryStatus` and `LibraryStatus`. Task 2's `RecordingFileAccess`.
- Produces:
  - `ProfileStore`:
    - `libraryStatus: LibraryStatus` (observable, `private(set)`)
    - `isLibraryMissing: Bool`, now computed: `.missing` or `.noAccess`
    - `fileAccess: any FileAccess`, which is `settings.fileAccess`
  - The library grant starts when a profile activates and stops when it deactivates. A removed profile's grant is forgotten.

- [ ] **Step 1: Write the failing tests**

In `Tests/ProfileStoreTests.swift`, replace `makeStore()` and `storeInWork()` with:

```swift
    private func makeStore(access: RecordingFileAccess = RecordingFileAccess()) -> ProfileStore {
        let settings = AppSettings()
        // Never write the real settings.json from a test.
        settings.suspendPersistence()
        settings.fileAccess = access
        return ProfileStore(
            settings: settings, jobStores: [], gallery: GalleryStore(),
            coordinator: GenerationCoordinator(), paths: paths, defaults: defaults
        )
    }

    /// Creates "Work" and switches into it, as New Profile does.
    private func storeInWork(access: RecordingFileAccess = RecordingFileAccess()) throws -> (ProfileStore, UUID) {
        let store = makeStore(access: access)
        let id = try store.createProfile(name: "Work", libraryPath: library.path).get()
        store.requestSwitch(to: id)
        store.completePendingSwitch()
        #expect(store.activeProfileID == id)
        return (store, id)
    }
```

Add these tests above `deinit`:

```swift
    /// Spec §4: a profile's library grant starts when the profile activates and
    /// stops when it deactivates.
    @Test func theActiveLibraryIsHeldUntilTheProfileSwitchesAway() throws {
        let access = RecordingFileAccess()
        let work = ProfileStore.resolvedPath(library.path)
        let (store, _) = try storeInWork(access: access)
        #expect(access.isHeld(work))

        store.requestSwitch(to: try #require(store.defaultProfileID))
        store.completePendingSwitch()

        #expect(!access.isHeld(work))
    }

    @Test func aLibraryWithoutAccessShowsTheBanner() throws {
        let access = RecordingFileAccess()
        access.unreachable = [ProfileStore.resolvedPath(library.path)]
        let (store, _) = try storeInWork(access: access)
        #expect(store.libraryStatus == .noAccess)
        #expect(store.isLibraryMissing)
    }

    @Test func regainedAccessIsPickedUpOnRefresh() throws {
        let access = RecordingFileAccess()
        let work = ProfileStore.resolvedPath(library.path)
        access.unreachable = [work]
        let (store, _) = try storeInWork(access: access)

        access.unreachable = []
        store.refreshLibraryAvailability()

        #expect(store.libraryStatus == .available)
        #expect(access.isHeld(work))
    }

    /// The profile's Inputs/ copies live in its data folder, so they go with it.
    @Test func removingAProfileForgetsItsLibraryAndDeletesItsInputs() throws {
        let access = RecordingFileAccess()
        let (store, workID) = try storeInWork(access: access)
        let inputs = paths.dataDirectory(for: workID).appendingPathComponent("Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)

        store.removeActiveProfile()
        store.completePendingSwitch()

        #expect(!FileManager.default.fileExists(atPath: inputs.path))
        #expect(access.forgotten == [ProfileStore.resolvedPath(library.path)])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run `ProfileStoreTests`.
Expected: build failure, `value of type 'ProfileStore' has no member 'libraryStatus'`.

- [ ] **Step 3: Implement in `Stores/ProfileStore.swift`**

**Status.** Replace the `isLibraryMissing` stored property and its doc comment with:

```swift
    /// Whether the active library can take images: drives the banner in
    /// ``ContentView`` and the Settings library section.
    private(set) var libraryStatus: LibraryStatus = .unset
```

**Properties.** After `@ObservationIgnored private var pendingRemoval: UUID?`, add:

```swift
    /// Holds the active library's grant (spec §4); see ``restartLibraryLease()``.
    @ObservationIgnored private var libraryLease: FileAccessLease?
```

After the `defaultProfileID` computed property, add:

```swift
    /// The active profile has a folder the app can't use right now: missing, or
    /// (App Store build) without access.
    var isLibraryMissing: Bool {
        libraryStatus == .missing || libraryStatus == .noAccess
    }

    /// The app's file access, for the views that choose library folders.
    var fileAccess: any FileAccess {
        settings.fileAccess
    }
```

**Removal.** In `completePendingSwitch()`, directly after `let removing = pendingRemoval`, add:

```swift
        let removedLibrary = registry.profiles.first { $0.id == removing }?.libraryPath
```

Then change the `if let removing { deleteData(for: removing) }` block to:

```swift
            if let removing {
                deleteData(for: removing)
                if let removedLibrary, !removedLibrary.isEmpty {
                    settings.fileAccess.forget(removedLibrary)
                }
            }
```

**Change Folder.** In `changeActiveLibrary(to:createIfMissing:)`, change the lines after `registry = next` to:

```swift
        settings.applyLibraryPath(resolved)
        restartLibraryLease()
        gallery.activate(thumbnailDirectory: paths.thumbnailDirectory(for: id), preservingLocks: true)
        gallery.scan(outputDir: resolved)
        refreshLibraryAvailability()
        return nil
```

**Refresh.** Replace `refreshLibraryAvailability()` with:

```swift
    /// Re-checks the active library folder, holding its grant while it's there,
    /// and rescans when it comes back.
    func refreshLibraryAvailability() {
        restartLibraryLease()
        let status = settings.libraryStatus
        let cameBack = isLibraryMissing && status == .available
        libraryStatus = status
        if cameBack {
            gallery.scan(outputDir: settings.outputDir)
        }
    }
```

**Lease helper.** Add to the `// MARK: - Private` section:

```swift
    /// Holds the active library's grant: started when a profile activates (or
    /// its drive comes back), ended when another takes its place. The new lease
    /// starts before the old ends.
    private func restartLibraryLease() {
        let next = settings.fileAccess.beginAccess(toAvailable: [settings.outputDir])
        libraryLease?.end()
        libraryLease = next
    }
```

`activateCurrentProfile()` already ends with `refreshLibraryAvailability()`, so activation and switching pick up the lease with no other change.

- [ ] **Step 4: Banner and Settings text**

In `Views/Profiles/MissingLibraryBanner.swift`, change `Text(error ?? "Library folder not found: \(settings.outputDir)")` to `Text(error ?? message)`. Change its `.help(...)` to `.help("Reconnect the drive it's on, or choose the folder (again) for this profile.")`. Then add below `body`:

```swift
    private var message: String {
        profiles.libraryStatus == .noAccess
            ? "Choose the library folder again to give the app access: \(settings.outputDir)"
            : "Library folder not found: \(settings.outputDir)"
    }
```

In `Views/Settings/SettingsView.swift`'s library section, insert this branch before `} else if profiles.isLibraryMissing {`:

```swift
                    } else if profiles.libraryStatus == .noAccess {
                        Label(
                            "Choose this folder again with Change… to give the app access.",
                            systemImage: "lock.fill"
                        )
                        .font(.caption).foregroundStyle(.orange)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run `ProfileStoreTests`.
Expected: 7 tests pass (3 existing and 4 new). Then run the full suite. Expected: all pass.

- [ ] **Step 6: Lint and commit**

```bash
git add Stores/ProfileStore.swift Views/Profiles/MissingLibraryBanner.swift Views/Settings/SettingsView.swift \
  Tests/ProfileStoreTests.swift
git commit -m "feat: hold the active library's grant and show when access is missing"
```

---

### Task 5: Each job holds what it reads

**Files:**
- Modify: `Runner/JobRunner.swift`: the `JobRunnerSpec` protocol, and `run(_:settings:timing:)` at the library guard
- Modify: `Runner/FluxJobRunner.swift`, `Runner/Krea2JobRunner.swift`, `Runner/ZImageJobRunner.swift`, `Runner/Ideogram4JobRunner.swift`, `Runner/SeedVR2JobRunner.swift`
- Test: `Tests/JobAccessPathsTests.swift`

**Interfaces:**
- Consumes: Task 3's `settings.libraryStatus` and `settings.fileAccess`; Task 1's `FileAccessPath.isLocal`.
- Produces: `static func accessPaths(job: Job) -> [String]` on every spec. It returns the local paths only.

- [ ] **Step 1: Write the failing test**

`Tests/JobAccessPathsTests.swift`:

```swift
@testable import MLXBits_Image_Studio
import Testing

/// What each family's job reads while it runs: LoRA files, a local model folder
/// and source images. FileAccess holds them open for the job (spec §4). Repo IDs
/// and empty fields aren't files and are left out.
struct JobAccessPathsTests {
    private let lora = LoraEntry(path: "/Loras/style.safetensors")

    @Test func fluxReadsItsLorasModelAndImages() {
        let job = FluxJob(
            customModelRepo: "/Models/klein", loras: [lora], imagePath: "/Lib/a.png", editImagePaths: ["/Lib/b.png"]
        )
        #expect(Set(FluxRunnerSpec.accessPaths(job: job))
            == ["/Loras/style.safetensors", "/Models/klein", "/Lib/a.png", "/Lib/b.png"])
    }

    @Test func krea2AndZImageReadTheirLorasModelAndImage() {
        let krea2 = Krea2Job(customModelRepo: "/Models/k2", loras: [lora], imagePath: "/Lib/a.png")
        let zimage = ZImageJob(customModelRepo: "/Models/z", loras: [lora], imagePath: "/Lib/a.png")
        #expect(Set(Krea2RunnerSpec.accessPaths(job: krea2)) == ["/Loras/style.safetensors", "/Models/k2", "/Lib/a.png"])
        #expect(Set(ZImageRunnerSpec.accessPaths(job: zimage)) == ["/Loras/style.safetensors", "/Models/z", "/Lib/a.png"])
    }

    @Test func ideogramReadsItsLorasAndModel() {
        let job = Ideogram4Job(customModelRepo: "/Models/i4", loras: [lora])
        #expect(Set(Ideogram4RunnerSpec.accessPaths(job: job)) == ["/Loras/style.safetensors", "/Models/i4"])
    }

    @Test func seedVR2ReadsItsSource() {
        #expect(SeedVR2RunnerSpec.accessPaths(job: SeedVR2Job(sourcePath: "/Lib/a.png")) == ["/Lib/a.png"])
    }

    @Test func repoIDsAreLeftOut() {
        let job = FluxJob(customModelRepo: "org/model", loras: [LoraEntry(path: "org/lora")])
        #expect(FluxRunnerSpec.accessPaths(job: job).isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run `xcodegen generate` (and restore the scheme), then `JobAccessPathsTests`.
Expected: build failure, `type 'FluxRunnerSpec' has no member 'accessPaths'`.

- [ ] **Step 3: Add the requirement and the five implementations**

In `Runner/JobRunner.swift`'s `JobRunnerSpec`, directly after `static func tool(job: Job) -> PythonTool`, add:

```swift
    /// Local files and folders the job reads (LoRAs, a local model folder,
    /// source images). FileAccess holds them open while it runs (spec §4).
    /// Repo IDs and empty fields are left out.
    static func accessPaths(job: Job) -> [String]
```

Add to `FluxRunnerSpec`, after its `tool(job:)`:

```swift
    static func accessPaths(job: FluxJob) -> [String] {
        (job.loras.map(\.path) + [job.customModelRepo, job.imagePath] + job.editImagePaths)
            .filter(FileAccessPath.isLocal)
    }
```

Add to `Krea2RunnerSpec`, after its `tool(job:)`:

```swift
    static func accessPaths(job: Krea2Job) -> [String] {
        (job.loras.map(\.path) + [job.customModelRepo, job.imagePath]).filter(FileAccessPath.isLocal)
    }
```

Add to `ZImageRunnerSpec`, after its `tool(job:)`:

```swift
    static func accessPaths(job: ZImageJob) -> [String] {
        (job.loras.map(\.path) + [job.customModelRepo, job.imagePath]).filter(FileAccessPath.isLocal)
    }
```

Add to `Ideogram4RunnerSpec`, after its `tool(job:)`:

```swift
    static func accessPaths(job: Ideogram4Job) -> [String] {
        (job.loras.map(\.path) + [job.customModelRepo]).filter(FileAccessPath.isLocal)
    }
```

Add to `SeedVR2RunnerSpec`, after its `tool(job:)`:

```swift
    static func accessPaths(job: SeedVR2Job) -> [String] {
        [job.sourcePath].filter(FileAccessPath.isLocal)
    }
```

- [ ] **Step 4: Hold them in `run`**

In `Runner/JobRunner.swift` `run(_:settings:timing:)`, replace the library guard: from `guard settings.libraryRootExists() else {` through its closing `}`, the `let reason = …` lines included. Keep the two comment lines above it. The replacement:

```swift
        if let reason = settings.libraryStatus.jobFailureReason(path: settings.outputDir) {
            finishJob(job, status: .failed(reason), stepDir: stepDir)
            return
        }
        // LoRA files, a local model and source images, held for the whole run
        // (spec §4). A LoRA picked from anywhere fails here, by name, if its
        // grant is gone.
        let access: FileAccessLease
        do {
            access = try settings.fileAccess.beginAccess(to: Spec.accessPaths(job: job))
        } catch {
            finishJob(job, status: .failed(error.localizedDescription), stepDir: stepDir)
            return
        }
        defer { access.end() }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run `JobAccessPathsTests`.
Expected: 5 tests pass. Then run the full suite, and the App Store compile from Global Constraints. Expected: all tests pass, and the build succeeds.

- [ ] **Step 6: Lint and commit**

```bash
git add Runner/*.swift Tests/JobAccessPathsTests.swift "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: jobs hold their LoRA files, model folder and source images"
```

---

### Task 6: Pickers keep their grants; picker-only folder fields

Views only. AGENTS.md: tests cover pure logic, so this task is verified by building both flavors.

**Files:**
- Create: `Views/Shared/GrantingPanel.swift`
- Create: `Views/Shared/PathField.swift` (`PathField` and `GrantHint`)
- Create: `Views/Settings/StorageSettingsRows.swift`
- Modify: `Views/Shared/LibraryFolderPanel.swift`, `Views/Settings/SettingsView.swift`, `Views/Profiles/ProfileEditorSheet.swift`, `Views/Profiles/MissingLibraryBanner.swift`
- Modify: `Views/Settings/OutputDirectoryPromptView.swift` (`pickFolder` only)
- Modify: `Views/Settings/ModelDefaultsView+Fields.swift`, `Views/Settings/ModelDefaultsView+Rows.swift`
- Modify: `Views/Settings/PromptLLMSettingsView.swift`, `Views/ParamsPanel/ModelPickerView.swift`

**Interfaces:**
- Consumes: Task 4's `profiles.fileAccess`; Task 3's `settings.fileAccess`; Task 1's `FileAccessPath`.
- Produces:
  - `GrantingPanel.chooseFolder(title:message:startingAt:showsHiddenFiles:access:) -> String?`
  - `GrantingPanel.chooseFile(title:message:startingAt:access:) -> String?`
  - `LibraryFolderPanel.choose(title:message:near:access:) -> String?`
  - `PathField(placeholder:path:browse:onReset:)`
  - `GrantHint(path:remedy:)`

- [ ] **Step 1: Write `Views/Shared/GrantingPanel.swift`**

```swift
import AppKit

/// Open panels whose choice the app keeps access to. Each chosen folder or
/// file is remembered through ``FileAccess`` before its path is returned, so
/// the App Store build reaches it again after a relaunch (spec §4); the DMG's
/// FileAccess ignores the call. Source-image pickers don't need this: those
/// images are copied into the profile (``AppSettings/adoptSourceImage(_:)``).
enum GrantingPanel {
    /// `startingAt` opens the panel *in* that folder. With nothing selected,
    /// Choose picks it — one click for the first-run models step.
    static func chooseFolder(
        title: String,
        message: String? = nil,
        startingAt start: URL? = nil,
        showsHiddenFiles: Bool = false,
        access: any FileAccess
    ) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = showsHiddenFiles
        configure(panel, title: title, message: message, start: start)
        return run(panel, access: access)
    }

    static func chooseFile(
        title: String, message: String? = nil, startingAt start: URL? = nil, access: any FileAccess
    ) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = true
        configure(panel, title: title, message: message, start: start)
        return run(panel, access: access)
    }

    private static func configure(_ panel: NSOpenPanel, title: String, message: String?, start: URL?) {
        panel.allowsMultipleSelection = false
        panel.title = title
        panel.prompt = "Choose"
        if let message {
            panel.message = message
        }
        if let start {
            panel.directoryURL = start
        }
    }

    private static func run(_ panel: NSOpenPanel, access: any FileAccess) -> String? {
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        access.remember(url)
        return url.path
    }
}
```

- [ ] **Step 2: Route `LibraryFolderPanel` through it**

Replace `LibraryFolderPanel.choose` in `Views/Shared/LibraryFolderPanel.swift` with the version below. Keep the `NSOpenPanel.startInLibrary` extension.

```swift
    /// Runs the panel and returns the chosen folder's path, or `nil` on cancel.
    /// `near` opens the panel beside that folder rather than wherever the last
    /// panel was, which could be inside another profile's library. The choice
    /// is remembered through `access`.
    static func choose(
        title: String, message: String? = nil, near path: String? = nil, access: any FileAccess
    ) -> String? {
        let start = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).deletingLastPathComponent() }
        return GrantingPanel.chooseFolder(
            title: title,
            message: message,
            startingAt: start ?? URL(fileURLWithPath: FileAccessPath.realHome, isDirectory: true),
            access: access
        )
    }
```

Update the four callers:
- **`SettingsView.changeLibraryFolder()`:** add `access: profiles.fileAccess`.
- **`ProfileEditorSheet.browse()`:** add `access: profiles.fileAccess`.
- **`MissingLibraryBanner.changeFolder()`:** add `near: settings.outputDir, access: profiles.fileAccess`. Choosing the same folder again is how access comes back.
- **`OutputDirectoryPromptView.pickFolder()`:** add `access: profiles.fileAccess`.

- [ ] **Step 3: Write `Views/Shared/PathField.swift`**

```swift
import SwiftUI

/// A folder setting with Browse…. In the App Store build it's picker-only: a
/// typed path carries no sandbox grant (spec §4), so the path shows read-only,
/// with an × that resets it to the default.
struct PathField: View {
    let placeholder: String
    @Binding var path: String
    let browse: () -> Void
    var onReset: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if BuildFlavor.isAppStore {
                Text(path.isEmpty ? placeholder : path)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onReset, !path.isEmpty {
                    Button(action: onReset) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.iconButtonCompact)
                    .help("Use the default")
                    .accessibilityLabel("Use the default")
                }
            } else {
                TextField(placeholder, text: $path)
                    .textFieldStyle(.roundedBorder)
            }
            Button("Browse…", action: browse)
        }
    }
}

/// Under a field that takes either a Hugging Face repo ID or a local folder:
/// says when the folder typed there can't be opened. Only the App Store build
/// can fail this way: a typed path has no grant until it's chosen with the
/// field's button. The DMG's FileAccess reaches everything, so it never shows.
struct GrantHint: View {
    @Environment(AppSettings.self) private var settings
    let path: String
    var remedy = "Choose it with Browse… to give access."

    var body: some View {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if FileAccessPath.isLocal(trimmed), !settings.fileAccess.canReach(trimmed) {
            Label("The app can't open this folder. \(remedy)", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
```

- [ ] **Step 4: Write `Views/Settings/StorageSettingsRows.swift`, and use it in Settings**

```swift
import SwiftUI

/// Settings ▸ Advanced ▸ HuggingFace: where models and mflux's converted
/// weights live. Picker-only in the App Store build, where empty means inside
/// the app's container (spec §4).
struct StorageSettingsRows: View {
    @Environment(AppSettings.self) private var settings

    private var placeholder: String {
        BuildFlavor.isAppStore ? "Inside the app (default)" : ""
    }

    var body: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 4) {
            PathField(
                placeholder: placeholder, path: $s.hfHome,
                browse: { chooseFolder(for: \.hfHome, title: "Choose Models Folder", start: modelsStart) },
                onReset: { s.hfHome = "" }
            )
            Text(BuildFlavor.isAppStore
                ? "Where models are downloaded. Choose your Hugging Face cache (~/.cache/huggingface) "
                + "to share models with other tools."
                : "Where HuggingFace caches downloaded model files. Default: ~/.cache/huggingface")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)

        VStack(alignment: .leading, spacing: 4) {
            PathField(
                placeholder: placeholder, path: $s.mfluxCacheDir,
                browse: { chooseFolder(for: \.mfluxCacheDir, title: "Choose mflux Cache Directory", start: nil) },
                onReset: { s.mfluxCacheDir = "" }
            )
            Text(BuildFlavor.isAppStore
                ? "Where mflux stores converted weight files."
                : "Where mflux stores converted weight files. Default: ~/Library/Caches/mflux")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// The current models folder, or the person's Hugging Face cache when there is one.
    private var modelsStart: URL? {
        settings.hfHome.isEmpty
            ? FileAccessPath.existingHuggingFaceCache()
            : URL(fileURLWithPath: settings.hfHome, isDirectory: true)
    }

    private func chooseFolder(for field: ReferenceWritableKeyPath<AppSettings, String>, title: String, start: URL?) {
        if let path = GrantingPanel.chooseFolder(
            title: title, startingAt: start, showsHiddenFiles: start != nil, access: settings.fileAccess
        ) {
            settings[keyPath: field] = path
        }
    }
}
```

`FileAccessPath.existingHuggingFaceCache()` arrives in Task 9. Add it now so this compiles: the Task 9 step 3 code, its first function only, in `Utilities/FileAccessPath.swift`. Task 9 adds its test.

In `Views/Settings/SettingsView.swift`'s `Section("HuggingFace")`:
- Replace the two `VStack(alignment: .leading, spacing: 4) { … }.padding(.vertical, 2)` blocks for `$s.hfHome` and `$s.mfluxCacheDir` with one line, `StorageSettingsRows()`.
- Delete `browseHFHome()` and `browseMfluxCacheDir()`.

- [ ] **Step 5: New Profile's library field is picker-only in the App Store build**

In `Views/Profiles/ProfileEditorSheet.swift`, replace:

```swift
                    HStack {
                        TextField("/path/to/folder", text: $libraryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browse() }
                    }
```

with:

```swift
                    PathField(
                        placeholder: BuildFlavor.isAppStore ? "No folder chosen" : "/path/to/folder",
                        path: $libraryPath,
                        browse: { browse() }
                    )
```

- [ ] **Step 6: Repo-or-path fields grant on Browse and warn when they can't open the folder**

**`modelRepoField`** in `Views/Settings/ModelDefaultsView+Fields.swift`. Wrap the returned `LabeledContent` and keep its accessibility label on it:

```swift
        return VStack(alignment: .trailing, spacing: 2) {
            LabeledContent("Model source") {
                // … the existing HStack, unchanged …
            }
            .accessibilityLabel("Model source override for \(model.displayName)")
            GrantHint(path: current ?? "")
        }
```

Then replace `browseModelDir(binding:)` with:

```swift
    func browseModelDir(binding: Binding<String>) {
        if let path = GrantingPanel.chooseFolder(title: "Select Model Directory", access: settings.fileAccess) {
            binding.wrappedValue = path
        }
    }
```

**`ModelSourceField.body`** in `Views/Settings/ModelDefaultsView+Rows.swift`. Wrap it the same way:

```swift
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            LabeledContent("Model source") {
                // … the existing HStack, unchanged …
            }
            GrantHint(path: repo)
        }
    }
```

**The Gemma field** in `Views/Settings/PromptLLMSettingsView.swift` `localFields`. Replace the `TextField("mlx-community/gemma-3-12b-it-4bit", text: $s.gemmaModelPath).textFieldStyle(.roundedBorder)` line with:

```swift
            HStack {
                TextField("mlx-community/gemma-3-12b-it-4bit", text: $s.gemmaModelPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    if let path = GrantingPanel.chooseFolder(
                        title: "Choose Gemma Model Folder", access: settings.fileAccess
                    ) {
                        settings.gemmaModelPath = path
                    }
                }
            }
```

After its caption `Text("HF repo ID or local path for the Gemma model.")…`, add `GrantHint(path: s.gemmaModelPath)`.

**The params panel's custom model field** in `Views/ParamsPanel/ModelPickerView.swift`. Replace `customRepoField` and add `chooseCustomFolder()` to the private methods. The HStack keeps the field's current 220 pt, inside the panel's 305 pt row budget (AGENTS.md):

```swift
    private var customRepoField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                TextField("org/repo or /path/to/model", text: $customModelRepo)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 196)
                    .accessibilityLabel("Custom model repo or path")
                Button {
                    chooseCustomFolder()
                } label: {
                    Image(systemName: "folder").font(.caption)
                }
                .buttonStyle(.iconButtonCompact)
                .frame(width: 20)
                .help("Choose a local model folder")
                .accessibilityLabel("Choose a local model folder")
            }
            GrantHint(path: customModelRepo, remedy: "Choose it with the folder button to give access.")
        }
    }
```

```swift
    private func chooseCustomFolder() {
        if let path = GrantingPanel.chooseFolder(title: "Choose Model Folder", access: settings.fileAccess) {
            customModelRepo = path
        }
    }
```

- [ ] **Step 7: Build both flavors**

Run `xcodegen generate` (and restore the scheme), then the full suite, then the App Store compile.
Expected: all tests pass and both builds succeed. `wc -l Views/Settings/SettingsView.swift` stays under 500.

- [ ] **Step 8: Lint and commit**

```bash
git add Views Utilities/FileAccessPath.swift "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: open panels keep their grants; folder fields are picker-only in the App Store build"
```

---

### Task 7: LoRA files: grant on pick, warn and Locate… when lost

**Files:**
- Modify: `Stores/LoraLibraryStore.swift` (a static `relocating` and an instance `relocate`)
- Modify: `Views/Settings/LoraLibraryEditorView.swift` (rows, and `LibraryLoraEditSheet.browse`)
- Modify: `Views/ParamsPanel/LoraManagerView.swift` (`browseLocalFile`, and `LoraRowView`)
- Test: `Tests/LoraRelocateTests.swift`

**Interfaces:**
- Consumes: Task 6's `GrantingPanel.chooseFile`, and `settings.fileAccess`.
- Produces:
  - `LoraLibraryStore.relocating(_:to:library:stacks:) -> (library: [LibraryLora], stacks: [LoraStack])`
  - `LoraLibraryStore.relocate(_:to:)`

- [ ] **Step 1: Write the failing test**

`Tests/LoraRelocateTests.swift`:

```swift
@testable import MLXBits_Image_Studio
import Testing

/// Locate… on a LoRA whose file was lost points its library entry at the new
/// file, and every saved stack that used the old path follows it.
struct LoraRelocateTests {
    @Test func locatingMovesTheEntryAndTheStacksThatUseIt() {
        let entry = LibraryLora(name: "Style", path: "/old/style.safetensors")
        let other = LibraryLora(name: "Other", path: "/old/other.safetensors")
        let stack = LoraStack(
            name: "Combo",
            loras: [LoraEntry(path: "/old/style.safetensors"), LoraEntry(path: "/old/other.safetensors")]
        )

        let next = LoraLibraryStore.relocating(
            entry.id, to: "/new/style.safetensors", library: [entry, other], stacks: [stack]
        )

        #expect(next.library.map(\.path) == ["/new/style.safetensors", "/old/other.safetensors"])
        #expect(next.stacks[0].loras.map(\.path) == ["/new/style.safetensors", "/old/other.safetensors"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run `xcodegen generate` (and restore the scheme), then `LoraRelocateTests`.
Expected: build failure, `type 'LoraLibraryStore' has no member 'relocating'`.

- [ ] **Step 3: Implement in `Stores/LoraLibraryStore.swift`**

Add directly after `private static let fileURL` (type methods go before instance properties):

```swift
    /// `library` and `stacks` with entry `id` moved to `newPath` (Locate…), and
    /// every stack LoRA that used its old path following it.
    static func relocating(
        _ id: UUID, to newPath: String, library: [LibraryLora], stacks: [LoraStack]
    ) -> (library: [LibraryLora], stacks: [LoraStack]) {
        guard let index = library.firstIndex(where: { $0.id == id }) else { return (library, stacks) }
        let oldPath = library[index].path
        var library = library
        library[index].path = newPath
        let stacks = stacks.map { stack in
            var stack = stack
            for i in stack.loras.indices where stack.loras[i].path == oldPath {
                stack.loras[i].path = newPath
            }
            return stack
        }
        return (library, stacks)
    }
```

Add to `// MARK: - Mutations`:

```swift
    func relocate(_ id: UUID, to newPath: String) {
        let next = Self.relocating(id, to: newPath, library: library, stacks: stacks)
        library = next.library
        stacks = next.stacks
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run `LoraRelocateTests`.
Expected: 1 test passes.

- [ ] **Step 5: Pickers grant; rows warn and offer Locate…**

**`LibraryLoraEditSheet.browse()`** in `Views/Settings/LoraLibraryEditorView.swift`. The sheet needs `@Environment(AppSettings.self) private var settings`; add it if missing. Then the body becomes:

```swift
    private func browse() {
        if let path = GrantingPanel.chooseFile(
            title: "Select LoRA", message: "Choose a .safetensors LoRA file", access: settings.fileAccess
        ) {
            draft.path = path
        }
    }
```

**`LoraLibraryEditorView.row(_:)`.** Inside the name `VStack(alignment: .leading, spacing: 3)`, after the trigger-words `if`, add:

```swift
                if isLost(entry) {
                    HStack(spacing: 6) {
                        Label("Access lost", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Button("Locate…") { locate(entry) }
                            .buttonStyle(.link)
                            .font(.caption2)
                    }
                }
```

Then add to `LoraLibraryEditorView`, after `row(_:)`:

```swift
    /// A local LoRA file the app can't open any more: deleted, moved, or (App
    /// Store build) its grant gone. Never true in the DMG, or for server LoRAs.
    private func isLost(_ entry: LibraryLora) -> Bool {
        !entry.isServerLoRA && FileAccessPath.isLocal(entry.path) && !settings.fileAccess.canReach(entry.path)
    }

    private func locate(_ entry: LibraryLora) {
        let old = URL(fileURLWithPath: entry.path)
        if let path = GrantingPanel.chooseFile(
            title: "Locate LoRA", message: "Choose \(old.lastPathComponent) again.",
            startingAt: old.deletingLastPathComponent(), access: settings.fileAccess
        ) {
            libraryStore.relocate(entry.id, to: path)
        }
    }
```

**`LoraManagerView`** in `Views/ParamsPanel/LoraManagerView.swift`:
- **Environment:** add `@Environment(AppSettings.self) private var settings`.
- **`browseLocalFile()`:**
  ```swift
      private func browseLocalFile() {
          if let path = GrantingPanel.chooseFile(
              title: "Select LoRA", message: "Choose a .safetensors LoRA file", access: settings.fileAccess
          ) {
              newPath = path
          }
      }
  ```
- **In `loraList`,** pass two more arguments to `LoraRowView`, after `onMoveDown:`:
  ```swift
                      isLost: FileAccessPath.isLocal(lora.path) && !settings.fileAccess.canReach(lora.path),
                      onLocate: { locate(lora.id) },
  ```
- **Add `locate(_:)` after `remove(id:)`:**
  ```swift
      /// Points this generation's LoRA at the file again, and its library entry with it.
      private func locate(_ id: UUID) {
          guard let index = loras.firstIndex(where: { $0.id == id }) else { return }
          let old = URL(fileURLWithPath: loras[index].path)
          guard let path = GrantingPanel.chooseFile(
              title: "Locate LoRA", message: "Choose \(old.lastPathComponent) again.",
              startingAt: old.deletingLastPathComponent(), access: settings.fileAccess
          ) else { return }
          if let entry = library?.libraryEntry(path: old.path) {
              library?.relocate(entry.id, to: path)
          }
          loras[index].path = path
      }
  ```

**`LoraRowView`.**
- **Properties:** add `var isLost = false` and `var onLocate: () -> Void = {}` after `var onMoveDown: () -> Void = {}`, and before `let onDelete`. They keep the memberwise order matching the call site.
- **Body:** in the `VStack(alignment: .leading, spacing: 6)`, after the first `HStack` (name and buttons), add:
  ```swift
              if isLost {
                  HStack(spacing: 6) {
                      Label("Access lost", systemImage: "exclamationmark.triangle.fill")
                          .font(.caption2)
                          .foregroundStyle(.orange)
                      Button("Locate…", action: onLocate)
                          .buttonStyle(.link)
                          .font(.caption2)
                  }
              }
  ```

- [ ] **Step 6: Build both flavors and run the full suite**

Run `xcodegen generate` (and restore the scheme), the full suite, and the App Store compile.
Expected: all pass, and both builds succeed.

- [ ] **Step 7: Lint and commit**

```bash
git add Stores/LoraLibraryStore.swift Views/Settings/LoraLibraryEditorView.swift Views/ParamsPanel/LoraManagerView.swift \
  Tests/LoraRelocateTests.swift "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: LoRA files keep their grant; lost ones offer Locate…"
```

---

### Task 8: Source images go through `adoptSourceImage` at every entry point

Views only. The import logic was tested in Tasks 2 and 3.

**Files:** modify `Views/ParamsPanel/ParamsPanelView.swift`, `Views/Krea2/Krea2ParamsPanelView.swift`, `Views/ZImage/ZImageParamsPanelView.swift` and `Views/ParamsPanel/PromptTemplatePickerView.swift`.

**Interfaces:** consumes Task 3's `settings.adoptSourceImage(_:)`. The DMG gets the path back unchanged. The App Store build copies outside images into `Inputs/`.

**Rule for every site below:** the path stored in params is the adopted one. `adoptResolvedPromptForImg2Img(at:)` still reads the *original* path, because a library image's metadata sidecar sits next to the original, not next to a copy.

- [ ] **Step 1: `ParamsPanelView`**

- **Image drop** (the `.imageDropTarget(extensions: Self.imageExtensions, isTargeted: $isImageDropTargeted)` closure):
  ```swift
              guard let path = paths.first else { return }
              params.imagePath = settings.adoptSourceImage(path)
              params.adoptResolvedPromptForImg2Img(at: path)
  ```
- **Edit-image drop** (the `allowsMultiple: true` closure):
  ```swift
              for path in paths.map({ settings.adoptSourceImage($0) }) where !params.editImagePaths.contains(path) {
                  params.editImagePaths.append(path)
              }
  ```
- **`pasteImage()`:** `params.imagePath = settings.adoptSourceImage(path)`
- **`browseImage()`:** `params.imagePath = settings.adoptSourceImage(url.path)`
- **`browseEditImages()`:** change the loop to:
  ```swift
              for path in valid.map({ settings.adoptSourceImage($0.path) }) where !params.editImagePaths.contains(path) {
                  params.editImagePaths.append(path)
              }
  ```
- **`pasteEditImage()`:**
  ```swift
          guard let pasted = imagePathFromPasteboard(tempPrefix: "pasted-edit") else { return }
          let path = settings.adoptSourceImage(pasted)
          if !params.editImagePaths.contains(path) {
              params.editImagePaths.append(path)
          }
  ```

- [ ] **Step 2: `Krea2ParamsPanelView` and `ZImageParamsPanelView`, the same four sites in each**

- **Drop closure:** `params.imagePath = settings.adoptSourceImage(path)`, keeping `params.adoptResolvedPromptForImg2Img(at: path)`.
- **`pasteImage()`, file-URL branch:** `params.imagePath = settings.adoptSourceImage(url.path)`.
- **`pasteImage()`, raw-data branch:** `params.imagePath = settings.adoptSourceImage(tmp.path)`.
- **`browseImage()`:** `params.imagePath = settings.adoptSourceImage(url.path)`.

- [ ] **Step 3: Template example image**

In `Views/ParamsPanel/PromptTemplatePickerView.swift`'s `TemplateEditSheet`:
- add `@Environment(AppSettings.self) private var settings`. The sheet is presented from `PromptTemplatePickerView`, so it has it.
- in `browseExampleImage()`, change `exampleImagePath = url.path` to `exampleImagePath = settings.adoptSourceImage(url.path)`.

- [ ] **Step 4: Check every entry point is covered**

Run:

```bash
grep -n 'imagePath = \(path\|url\.path\|tmp\.path\)$' \
  Views/ParamsPanel/ParamsPanelView.swift Views/Krea2/Krea2ParamsPanelView.swift Views/ZImage/ZImageParamsPanelView.swift
```

Expected: no output. The only remaining raw assignments are `= ""` (clear) and `useInImg2Img` in `ContentView`, whose gallery images are already in the library.

This grep can't see the three edit-image sites in `ParamsPanelView`, because each still ends in `append(path)`. Check those by eye: each must append a path that came out of `settings.adoptSourceImage`.

- [ ] **Step 5: Build both flavors and run the full suite**

Expected: all pass, and both builds succeed.

- [ ] **Step 6: Lint and commit**

```bash
git add Views
git commit -m "feat: source images from outside the library are copied into the profile"
```

---

### Task 9: First run: the Pictures default and the models-folder step

**Files:**
- Modify: `Utilities/FileAccessPath.swift`: add `defaultLibrary(isAppStore:home:)`; check `existingHuggingFaceCache(home:)` from Task 6
- Create: `Views/Settings/ModelsFolderStepView.swift`
- Modify: `Views/Settings/OutputDirectoryPromptView.swift`, `App/ContentView.swift`
- Test: `Tests/FirstRunPathsTests.swift`

**Interfaces:**
- Consumes: Task 6's `GrantingPanel.chooseFolder`; `settings.hfHome`.
- Produces:
  - `FileAccessPath.defaultLibrary(isAppStore:home:) -> String`
  - `FileAccessPath.existingHuggingFaceCache(home:) -> URL?`
  - `ModelsFolderStepView(onDone:)`, and `ModelsFolderStepView.doneKey`
  - `OutputDirectoryPromptView(isPresented:includeModelsStep:startAtModelsStep:)`

- [ ] **Step 1: Write the failing test**

`Tests/FirstRunPathsTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// First run in the App Store build (spec §4). Skip for Now makes the library
/// in Pictures, which the sandbox may write to. An existing Hugging Face cache
/// is offered as the models folder.
struct FirstRunPathsTests {
    @Test func skipForNowUsesPicturesInTheAppStoreBuild() {
        #expect(FileAccessPath.defaultLibrary(isAppStore: true, home: "/Users/me")
            == "/Users/me/Pictures/MLXBits Image Studio")
        #expect(FileAccessPath.defaultLibrary(isAppStore: false, home: "/Users/me") == "/Users/me/MLXBits Image Studio")
    }

    @Test func anExistingHuggingFaceCacheIsOffered() throws {
        let home = FakeRuntime.tempDirectory("FirstRunPathsTests")
        #expect(FileAccessPath.existingHuggingFaceCache(home: home.path) == nil)
        let cache = home.appendingPathComponent(".cache/huggingface", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        #expect(FileAccessPath.existingHuggingFaceCache(home: home.path)?.path == cache.path)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run `xcodegen generate` (and restore the scheme), then `FirstRunPathsTests`.
Expected: build failure, `type 'FileAccessPath' has no member 'defaultLibrary'`.

- [ ] **Step 3: Add the helpers to `FileAccessPath`**

`existingHuggingFaceCache` may already be there from Task 6 step 4. Make sure both functions exist exactly as below:

```swift
    /// `~/.cache/huggingface` in the person's real home, when it exists. The
    /// sandbox can `stat` it without a grant, though not list it.
    static func existingHuggingFaceCache(home: String = realHome) -> URL? {
        let cache = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".cache/huggingface", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cache.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return cache
    }

    /// Where Skip for Now makes the library. The DMG uses the home folder (not
    /// iCloud-synced). The App Store build uses Pictures: the sandbox may write
    /// there, and Finder shows it.
    static func defaultLibrary(isAppStore: Bool, home: String) -> String {
        isAppStore ? "\(home)/Pictures/MLXBits Image Studio" : "\(home)/MLXBits Image Studio"
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run `FirstRunPathsTests`.
Expected: 2 tests pass.

- [ ] **Step 5: Write `Views/Settings/ModelsFolderStepView.swift`**

```swift
import SwiftUI

/// The App Store build's first-run models step (spec §4). It offers the
/// person's Hugging Face cache when there is one; otherwise models stay in the
/// app's container, and Settings ▸ Advanced can move them later.
struct ModelsFolderStepView: View {
    /// Set once this step is answered, so it's shown on one launch only.
    static let doneKey = "firstRun.modelsFolderStepDone"

    @Environment(AppSettings.self) private var settings
    let onDone: () -> Void
    private let existingCache = FileAccessPath.existingHuggingFaceCache()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 6) {
                Text(existingCache == nil
                    ? "Where should models be stored?"
                    : "We found your Hugging Face model cache — use it?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let existingCache {
                    Text(existingCache.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            HStack(spacing: 12) {
                Button(existingCache == nil ? "Continue" : "Keep Models in the App") { onDone() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button(existingCache == nil ? "Choose Folder…" : "Use It…") { choose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 400)
    }

    private var explanation: String {
        existingCache == nil
            ? "Models download into the app's own storage. To keep them on another drive, choose a folder. "
            + "You can change this later in Settings ▸ Advanced."
            : "Models you've already downloaded with other tools are reused instead of downloaded again. "
            + "Click Choose in the next window to give the app access."
    }

    private func choose() {
        guard let path = GrantingPanel.chooseFolder(
            title: existingCache == nil ? "Choose Models Folder" : "Use Hugging Face Cache",
            message: existingCache == nil ? "Models will be downloaded here." : "Click Choose to use this folder for models.",
            startingAt: existingCache,
            showsHiddenFiles: existingCache != nil,
            access: settings.fileAccess
        ) else { return }
        settings.hfHome = path
        onDone()
    }
}
```

- [ ] **Step 6: Add the second step to `OutputDirectoryPromptView`**

These changes go in `Views/Settings/OutputDirectoryPromptView.swift`:

- **Doc comment** (replaces the existing one):
  ```swift
  /// Shown on first launch to choose the library folder. Skip for Now uses
  /// `~/MLXBits Image Studio` in the DMG (not iCloud-synced), and Pictures in
  /// the App Store build, whose sandbox may write there. In the App Store build
  /// the models-folder step follows (spec §4).
  ```
- **New properties,** after `@Environment(ProfileStore.self) private var profiles`:
  ```swift
      @AppStorage(ModelsFolderStepView.doneKey) private var modelsFolderStepDone = false
  ```
  and after `@Binding var isPresented: Bool`:
  ```swift
      /// App Store first run: follow the library step with the models step.
      let includeModelsStep: Bool
  ```
  and after `@State private var error: String?`:
  ```swift
      @State private var showingModelsStep: Bool
  ```
- **The body:** rename the existing `var body: some View` to `private var libraryStep: some View`, then add a new `body` above it:
  ```swift
      var body: some View {
          if showingModelsStep {
              ModelsFolderStepView {
                  modelsFolderStepDone = true
                  isPresented = false
              }
          } else {
              libraryStep
          }
      }
  ```
- **The `init`,** after `libraryStep` (instance properties come before `init`):
  ```swift
      init(isPresented: Binding<Bool>, includeModelsStep: Bool = false, startAtModelsStep: Bool = false) {
          _isPresented = isPresented
          self.includeModelsStep = includeModelsStep
          _showingModelsStep = State(initialValue: includeModelsStep && startAtModelsStep)
      }
  ```
- **Copy, in `libraryStep`.** The explanatory text becomes:
  ```swift
                  Text(BuildFlavor.isAppStore
                      ? "Choose any folder you control, or skip to save into Pictures ▸ MLXBits Image Studio."
                      : "Choose any folder you control. Avoid iCloud-synced folders like ~/Pictures"
                      + " or ~/Documents if you don't want generated images uploaded to iCloud.")
  ```
- **Skip for Now:**
  ```swift
                  Button("Skip for Now") {
                      error = profiles.changeActiveLibrary(
                          to: FileAccessPath.defaultLibrary(isAppStore: BuildFlavor.isAppStore, home: FileAccessPath.realHome),
                          createIfMissing: true
                      )?.message
                      if error == nil {
                          finishLibraryStep()
                      }
                  }
  ```
  Its `.accessibilityHint` becomes `BuildFlavor.isAppStore ? "Saves to Pictures ▸ MLXBits Image Studio" : "Saves to ~/MLXBits Image Studio — not inside Pictures or Documents"`.
- **Done:** its action becomes `finishLibraryStep()`.
- **New method,** after `pickFolder()`:
  ```swift
      private func finishLibraryStep() {
          if includeModelsStep {
              showingModelsStep = true
          } else {
              isPresented = false
          }
      }
  ```

Settings' info button keeps calling `OutputDirectoryPromptView(isPresented:)`, so it shows the library step only.

- [ ] **Step 7: Wire it into `ContentView`**

In `App/ContentView.swift`:

- **New property,** next to `@State private var showingOutputDirPrompt`:
  ```swift
      @AppStorage(ModelsFolderStepView.doneKey) private var modelsFolderStepDone = false
  ```
- **New computed property,** next to the other computed properties:
  ```swift
      /// App Store first run: the models-folder step is still to come (spec §4).
      private var needsModelsStep: Bool {
          BuildFlavor.isAppStore && !modelsFolderStepDone
      }
  ```
- **The sheet in `bodyBase`:**
  ```swift
              .sheet(isPresented: $showingOutputDirPrompt) {
                  OutputDirectoryPromptView(
                      isPresented: $showingOutputDirPrompt,
                      includeModelsStep: needsModelsStep,
                      startAtModelsStep: !settings.outputDir.isEmpty
                  )
                  .environment(settings)
                  .environment(profiles)
              }
  ```
- **In the first `.onAppear`,** replace the `if settings.outputDir.isEmpty { … } else { gallery.scan(…) }` block with:
  ```swift
                  if settings.outputDir.isEmpty || needsModelsStep {
                      showingOutputDirPrompt = true
                  }
                  if !settings.outputDir.isEmpty {
                      gallery.scan(outputDir: settings.outputDir)
                  }
  ```

An install from before this milestone (the owner's TestFlight 0.16.0) already has a library. It opens straight on the models step, and its library banner offers Change Folder… to re-grant.

- [ ] **Step 8: Build both flavors and run the full suite**

Run `xcodegen generate` (and restore the scheme), the full suite, and the App Store compile.
Expected: all pass, and both builds succeed.

- [ ] **Step 9: Lint and commit**

```bash
git add Utilities/FileAccessPath.swift Views/Settings/ModelsFolderStepView.swift Views/Settings/OutputDirectoryPromptView.swift \
  App/ContentView.swift Tests/FirstRunPathsTests.swift "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: first run offers the Hugging Face cache and a Pictures library"
```

---

### Task 10: Gemma downloads owned by the app (#18)

**Files:**
- Create: `Stores/ModelDownloadStore.swift`
- Create: `Views/Shared/ModelDownloadStatusRow.swift`
- Create: `Tests/Support/AsyncGate.swift`
- Modify:
  - `Utilities/ScenarioGenerator.swift`, `Utilities/IdeogramCaptionGenerator.swift`
  - `Views/ParamsPanel/ScenarioGeneratorView.swift`, `Views/ParamsPanel/ScenarioBatchQueue.swift`
  - `Views/Ideogram4/IdeogramCaptionEditorView.swift`
  - `App/MLXBitsImageStudioApp.swift`
- Test: `Tests/ModelDownloadStoreTests.swift`; also append to `Tests/ScenarioGeneratorTests.swift`

**Interfaces:**
- Consumes: `settings.toolchain.command(.hf)`, `settings.buildEnvironment()`, `settings.hfHubDir`, `settings.hfOffline`; Task 1's `FileAccessPath.isLocal`.
- Produces:
  - `ModelDownloadStore`:
    - `init(fetch:)`
    - `active: [String: Download]`
    - `ensureAvailable(_:settings:) async throws`, `cancel(_:)`
    - static `needsFetch(_:offline:)`, `bytesOnDisk(repo:hubDir:)`, `hasSnapshot(repo:hubDir:)`
  - `ModelDownloadError.failed(repo:detail:)`
  - `AppSettings.gemmaModel: String`, and `AppSettings.defaultGemmaModel`
  - `ModelDownloadStatusRow(model:)`, and its static `describe(bytes:since:now:)`
  - `ScenarioSession.isLoadingModel`
  - `ScenarioGenerator.onModelLoading`; `ScenarioGenerator.handleEvent(_:)` becomes internal
  - New parameters: `ScenarioGenerator.generate(…, settings:downloads:)` and `IdeogramCaptionGenerator.generate(from:settings:downloads:)`

- [ ] **Step 1: Write the failing tests**

`Tests/Support/AsyncGate.swift`:

```swift
/// An awaitable switch for tests: `wait()` suspends until `open()`.
final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
```

`Tests/ModelDownloadStoreTests.swift`:

```swift
import Foundation
@testable import MLXBits_Image_Studio
import Testing

/// Model downloads the app owns (#18). A panel waits on one, but closing it or
/// cancelling its generation stops the wait, not the download.
struct ModelDownloadStoreTests {
    private func settings(offline: Bool = false) -> AppSettings {
        let settings = AppSettings()
        settings.suspendPersistence()
        settings.hfOffline = offline
        return settings
    }

    @Test func localPathsAndOfflineModeNeedNoFetch() async throws {
        var fetched: [String] = []
        let store = ModelDownloadStore { repo, _ in fetched.append(repo) }
        try await store.ensureAvailable("/Volumes/Models/gemma", settings: settings())
        try await store.ensureAvailable("mlx-community/gemma", settings: settings(offline: true))
        #expect(fetched.isEmpty)
    }

    @Test func aRepoIsFetchedOncePerLaunch() async throws {
        var fetched = 0
        let store = ModelDownloadStore { _, _ in fetched += 1 }
        let s = settings()
        try await store.ensureAvailable("mlx-community/gemma", settings: s)
        try await store.ensureAvailable("mlx-community/gemma", settings: s)
        #expect(fetched == 1)
    }

    @Test func cancellingTheCallerLeavesTheDownloadRunning() async throws {
        let gate = AsyncGate()
        var fetched = 0
        let store = ModelDownloadStore { _, _ in
            fetched += 1
            await gate.wait()
        }
        let s = settings()
        let caller = Task { try await store.ensureAvailable("mlx-community/gemma", settings: s) }
        while store.active["mlx-community/gemma"] == nil {
            await Task.yield()
        }

        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(store.active["mlx-community/gemma"] != nil)

        gate.open()
        try await store.ensureAvailable("mlx-community/gemma", settings: s)
        #expect(fetched == 1)
        #expect(store.active.isEmpty)
    }

    @Test func aFailedDownloadIsReportedAndRetriedNextTime() async throws {
        var attempts = 0
        let store = ModelDownloadStore { repo, _ in
            attempts += 1
            throw ModelDownloadError.failed(repo: repo, detail: "boom")
        }
        let s = settings()
        await #expect(throws: ModelDownloadError.self) { try await store.ensureAvailable("org/model", settings: s) }
        await #expect(throws: ModelDownloadError.self) { try await store.ensureAvailable("org/model", settings: s) }
        #expect(attempts == 2)
    }

    @Test func aFailedFetchWithACachedCopyStillRuns() async throws {
        let home = FakeRuntime.tempDirectory("ModelDownloadStoreTests")
        let snapshot = home.appendingPathComponent("hub/models--org--model/snapshots/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let s = settings()
        s.hfHome = home.path
        let store = ModelDownloadStore { _, _ in throw URLError(.notConnectedToInternet) }
        try await store.ensureAvailable("org/model", settings: s)
    }

    @Test func progressReadsAsSizeAndTime() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(ModelDownloadStatusRow.describe(bytes: 2_254_857_830, since: start, now: start.addingTimeInterval(65))
            == "2.1 GB · 1m 05s")
        #expect(ModelDownloadStatusRow.describe(bytes: 0, since: start, now: start.addingTimeInterval(7)) == "07s")
    }
}
```

Append to `Tests/ScenarioGeneratorTests.swift`, inside its suite type:

```swift
    /// The warm driver's loading/loaded events show as "Loading model…" (#18).
    @Test func modelLoadingEventsReachTheSession() {
        let session = ScenarioSession()
        session.generator.handleEvent(["event": "loading"])
        #expect(session.isLoadingModel)
        session.generator.handleEvent(["event": "loaded", "seconds": 3.2])
        #expect(!session.isLoadingModel)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run `xcodegen generate` (and restore the scheme), then `ModelDownloadStoreTests` and `ScenarioGeneratorTests`.
Expected: build failure, `cannot find 'ModelDownloadStore' in scope`.

- [ ] **Step 3: Write `Stores/ModelDownloadStore.swift`**

```swift
import Foundation

enum ModelDownloadError: LocalizedError, Equatable {
    case failed(repo: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .failed(repo, detail):
            "Couldn't download \(repo). \(detail)"
        }
    }
}

/// Model downloads the app owns, not a panel (#18).
///
/// The Scenario Generator and the Ideogram caption tool fetch their local Gemma
/// model here before running it. Closing the panel, or cancelling the
/// generation, stops the wait but not the download, and the panels show what
/// has landed so far.
@Observable
final class ModelDownloadStore {
    /// Fetches one Hugging Face repo into the cache. Swapped out in tests.
    typealias Fetch = (_ repo: String, _ settings: AppSettings) async throws -> Void

    struct Download: Equatable {
        let startedAt: Date
        var bytesOnDisk: Int64 = 0
    }

    /// `hf download <repo>` through the bundled toolchain, in a process of its own.
    private static let hfDownload: Fetch = { repo, settings in
        let hf = try settings.toolchain.command(.hf)
        let process = Process()
        process.executableURL = hf.executableURL
        process.arguments = hf.arguments + ["download", repo]
        process.environment = settings.buildEnvironment()
        process.standardOutput = FileHandle.nullDevice
        // stderr goes to a file: hf's progress bars would fill a pipe nobody reads.
        let errorLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-download-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorLog)
        process.standardError = errorHandle
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorLog)
        }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let tail = (try? String(contentsOf: errorLog, encoding: .utf8)).map { String($0.suffix(600)) } ?? ""
            throw ModelDownloadError.failed(repo: repo, detail: tail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Whether a local run of `model` needs it fetched first: a Hugging Face
    /// repo ID, while online.
    static func needsFetch(_ model: String, offline: Bool) -> Bool {
        !offline && !FileAccessPath.isLocal(model) && model.contains("/")
    }

    /// `models--org--name` under the hub cache.
    static func cacheFolder(repo: String, hubDir: URL) -> URL {
        hubDir.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// Bytes in the repo's blobs folder, `.incomplete` files included.
    static func bytesOnDisk(repo: String, hubDir: URL) -> Int64 {
        let blobs = cacheFolder(repo: repo, hubDir: hubDir).appendingPathComponent("blobs", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return entries.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Whether a snapshot of the repo is already cached, so a failed fetch
    /// (offline, Hub down) can still run it.
    static func hasSnapshot(repo: String, hubDir: URL) -> Bool {
        let snapshots = cacheFolder(repo: repo, hubDir: hubDir).appendingPathComponent("snapshots", isDirectory: true)
        return !((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []).isEmpty
    }

    /// Repos downloading now, with how much has landed.
    private(set) var active: [String: Download] = [:]

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var failures: [String: Error] = [:]
    /// Repos fetched this launch, which aren't fetched again.
    @ObservationIgnored private var ready: Set<String> = []

    init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? Self.hfDownload
    }

    /// Returns once `model` is in the cache. That's at once for a local path,
    /// in offline mode, or for a repo already fetched this launch. Otherwise it
    /// starts the download, or joins one in progress, and waits. Cancelling the
    /// caller ends the wait; the download carries on.
    func ensureAvailable(_ model: String, settings: AppSettings) async throws {
        guard Self.needsFetch(model, offline: settings.hfOffline), !ready.contains(model) else { return }
        if tasks[model] == nil {
            start(model, settings: settings)
        }
        while tasks[model] != nil {
            try await Task.sleep(for: .milliseconds(200))
        }
        if let error = failures[model] {
            throw error
        }
    }

    /// Stops a download (the status row's Stop button).
    func cancel(_ repo: String) {
        tasks[repo]?.cancel()
    }

    private func start(_ repo: String, settings: AppSettings) {
        failures[repo] = nil
        active[repo] = Download(startedAt: Date())
        let hubDir = settings.hfHubDir
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.active[repo]?.bytesOnDisk = Self.bytesOnDisk(repo: repo, hubDir: hubDir)
            }
        }
        tasks[repo] = Task { [weak self] in
            do {
                try await self?.fetch(repo, settings)
                self?.ready.insert(repo)
            } catch {
                if !(error is CancellationError), Self.hasSnapshot(repo: repo, hubDir: hubDir) {
                    self?.ready.insert(repo)
                } else {
                    self?.failures[repo] = error
                }
            }
            poll.cancel()
            self?.active[repo] = nil
            self?.tasks[repo] = nil
        }
    }
}

extension AppSettings {
    static let defaultGemmaModel = "mlx-community/gemma-3-12b-it-8bit"

    /// The Gemma model local runs use: the setting, or the default when it's empty.
    var gemmaModel: String {
        ((gemmaModelPath.isEmpty ? Self.defaultGemmaModel : gemmaModelPath) as NSString).expandingTildeInPath
    }
}
```

- [ ] **Step 4: Write `Views/Shared/ModelDownloadStatusRow.swift`**

```swift
import SwiftUI

/// While the app downloads `model` (``ModelDownloadStore``): how much has
/// landed, a Stop button, and a note that closing the window doesn't stop it (#18).
struct ModelDownloadStatusRow: View {
    @Environment(ModelDownloadStore.self) private var downloads
    let model: String

    /// "2.1 GB · 1m 05s", or just the time before any bytes land.
    static func describe(bytes: Int64, since start: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        let minutes = elapsed / 60
        let time = (minutes > 0 ? "\(minutes)m " : "") + String(format: "%02ds", elapsed % 60)
        guard bytes > 0 else { return time }
        return String(format: "%.1f GB · ", Double(bytes) / 1_073_741_824) + time
    }

    var body: some View {
        if let download = downloads.active[model] {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: download.startedAt, by: 1)) { context in
                        Text("Downloading \(model)… "
                            + Self.describe(bytes: download.bytesOnDisk, since: download.startedAt, now: context.date))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    Spacer()
                    Button("Stop") { downloads.cancel(model) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("First use only. It keeps going if you close this window.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
```

- [ ] **Step 5: Generators wait on the store; driver load events reach the session**

**`Utilities/ScenarioGenerator.swift`:**
- **Signature:** `generate(outline:categories:wildcardMode:settings:)` gains a last parameter, `downloads: ModelDownloadStore`.
- **The model lines:** replace the `let rawModel = …` / `let modelPath = (rawModel as NSString).expandingTildeInPath` lines with `let modelPath = settings.gemmaModel`. Keep the existence check and its comment after it.
- **Then add:**
  ```swift
          // Fetched by the app, not the driver, so closing the panel mid-download
          // doesn't throw the download away (#18).
          try await downloads.ensureAvailable(modelPath, settings: settings)
  ```
- **A new property,** after `private(set) var lastLog: String = ""`:
  ```swift
      /// Told when the warm driver starts and finishes loading the model, so
      /// the panel can say "Loading model…" rather than "Generating…".
      var onModelLoading: ((Bool) -> Void)?
  ```
- **`handleEvent(_:)`:** drop `private` and give it the doc comment `/// Internal for tests.` In its switch, replace the `default:` comment (`// loading/loaded — informational`) by adding these cases before `default:`:
  ```swift
          case "loading":
              onModelLoading?(true)
          case "loaded":
              onModelLoading?(false)
  ```
- **The `result` and `error` cases:** add `onModelLoading?(false)` as their first line.
- **`consumeStdout(_:)`, EOF branch:** add `onModelLoading?(false)` before `pending?.resume(throwing: error)`.

**`Utilities/IdeogramCaptionGenerator.swift`:**
- **Signature:** `generate(from:settings:)` gains a last parameter, `downloads: ModelDownloadStore`.
- **The local branch:** replace the three-line `let modelPath = settings.gemmaModelPath.isEmpty ? … : …` with:
  ```swift
              let modelPath = settings.gemmaModel
              try await downloads.ensureAvailable(modelPath, settings: settings)
  ```

**`Views/ParamsPanel/ScenarioGeneratorView.swift`:**
- **`ScenarioSession`:** add `var isLoadingModel: Bool = false` after `var isGenerating`. Then add, after `isBatching`:
  ```swift
      init() {
          generator.onModelLoading = { [weak self] loading in self?.isLoadingModel = loading }
      }
  ```
- **`ScenarioGeneratorView`:** after `@Environment(AppSettings.self) var settings`, add:
  ```swift
      /// Internal, not private: the batch-queue half lives in ScenarioBatchQueue.swift.
      @Environment(ModelDownloadStore.self) var downloads
  ```
- **`generatingRow`:** make `ModelDownloadStatusRow(model: settings.gemmaModel)` its first line, outside the `if session.isGenerating`, so a download that outlives a cancelled generation still shows. Inside the `if`, change the `Text(…)` to `Text(statusText)`, and add this property after `generatingRow`:
  ```swift
      private var statusText: String {
          if downloads.active[settings.gemmaModel] != nil {
              return "Waiting for the model download…"
          }
          if session.isLoadingModel {
              return "Loading model…"
          }
          return session.isBatching
              ? "Rolling prompt \(min(session.batchPrompts.count + 1, session.rollTarget))/\(session.rollTarget)…"
              : "Generating…"
      }
  ```
- **`startGenerate()`:** pass `downloads: downloads` to `generate`.
- **`ScenarioGeneratorButton`:** add `@Environment(ModelDownloadStore.self) private var downloads`, and pass `downloads: downloads` to `controller.toggle(…)`.
- **`ScenarioPanelController.toggle`:** gains `downloads: ModelDownloadStore` after `settings:`. The root view's `.environment(settings)` becomes `.environment(settings).environment(downloads)`.

**`Views/ParamsPanel/ScenarioBatchQueue.swift` `roll(_:)`:** pass `downloads: downloads`.

**`Views/Ideogram4/IdeogramCaptionEditorView.swift`:**
- **Environment:** add `@Environment(ModelDownloadStore.self) private var downloads`.
- **`startGenerate()`:** pass `downloads: downloads`.
- **`generateSection`:** directly after its first `Spacer()`, add `ModelDownloadStatusRow(model: settings.gemmaModel)`.
- **The button label:**
  ```swift
                          Text(isGenerating
                              ? (downloads.active[settings.gemmaModel] != nil ? "Downloading model…" : "Generating…")
                              : "Generate with Gemma")
  ```

**`App/MLXBitsImageStudioApp.swift`:**
- add `@State private var modelDownloads = ModelDownloadStore()` with the other `@State` stores;
- add `.environment(modelDownloads)` to the `WindowGroup` chain after `.environment(backendModels)`.

- [ ] **Step 6: Run the tests to verify they pass**

Run `xcodegen generate` (and restore the scheme), then `ModelDownloadStoreTests` and `ScenarioGeneratorTests`.
Expected: all pass: 6 new in `ModelDownloadStoreTests`, 1 new in `ScenarioGeneratorTests`. Then run the full suite and the App Store compile. Expected: all pass, and both builds succeed. `wc -l Utilities/ScenarioGenerator.swift Views/ParamsPanel/ScenarioGeneratorView.swift` both stay under 500.

- [ ] **Step 7: Lint and commit**

```bash
git add Stores/ModelDownloadStore.swift Views Utilities App Tests "MLXBits Image Studio.xcodeproj/project.pbxproj"
git commit -m "feat: the app owns the Gemma download and shows its progress

Refs #18"
```

---

### Task 11: Docs

**Files:** modify `docs/specs/2026-10-03-app-store-build-design.md`, `AGENTS.md` and `README.md`.

- [ ] **Step 1: Spec §4**

In the "Persistent folder grants" table:
- change the header `Bookmark stored in` to `Grant kept in`;
- change every cell under it to `grants.json, by path`.

After the table, add:

```markdown
**How grants are kept (decided in milestone 5).** One store, `grants.json` in App Support, holds every bookmark, keyed by the path it was made for. Bookmarks aren't fields on profiles, LoRAs or settings.
- **Coverage:** a path is reachable through the deepest grant at or above it. A LoRA downloaded into the models folder, or a source image in the library, needs nothing of its own.
- **Why one store:** jobs, drafts, saved stacks and settings all keep carrying plain paths.
- **A folder renamed or moved in Finder isn't followed:** it shows as missing, as in the DMG, until it's chosen again.
```

Make these replacements in §4:

| Where | Replace | With |
|---|---|---|
| "Picker only" bullet | `This includes the New Profile sheet's library field.` | `This includes the New Profile sheet's library field. Fields that also take a Hugging Face repo ID (model sources, the Gemma model, the custom model) stay typeable: Browse… grants access, and a typed folder the app can't open shows a hint.` |
| "Picked from anywhere" bullet | `each library entry gets a file bookmark (` + "`LoraEntry.bookmark`" + `), started for the duration of a job.` | `each picked file gets a grant, started for the duration of a job.` |
| Source images | `(open panel or drag and drop)` | `(open panel, drag and drop, or paste)` |
| First run, step 2 | `Settings ▸ Models can move them later` | `Settings ▸ Advanced can move them later` |

- [ ] **Step 2: Spec §7**

Replace the bullet `**Profile registry:** a ` + "`profiles.json`" + ` without ` + "`libraryBookmark`" + ` still loads.` with:

```markdown
- **Grant store:** the deepest covering grant wins; a sibling folder sharing a prefix isn't covered; a moved folder isn't followed; a stale bookmark is re-created.
```

- [ ] **Step 3: AGENTS.md**

In "Conventions and gotchas", replace the bullet "The app is unsandboxed (`com.apple.security.app-sandbox: false`) to reach user-chosen model directories." with:

```markdown
- The DMG is unsandboxed; the App Store flavor is sandboxed (`Utilities/FileAccess.swift`, spec §4). In both:
  - **Every open panel** that picks a folder or LoRA goes through `GrantingPanel` (or `LibraryFolderPanel`), so the App Store build keeps access across relaunches.
  - **Every new source-image entry point** passes its path through `settings.adoptSourceImage(_:)`.
  - **Anything a job reads from disk** goes in its spec's `accessPaths(job:)`.
```

- [ ] **Step 4: README**

In "Python runtime and the App Store flavor", after the paragraph ending "never touches the DMG app's data.", add:

```markdown
On first run the App Store flavor asks for a library folder (Skip for Now uses Pictures ▸ MLXBits Image Studio) and a models folder, offering `~/.cache/huggingface` when it exists. It keeps access to every folder and LoRA you choose. Images you bring in from outside the library are copied into the profile, so re-runs work after a relaunch.
```

- [ ] **Step 5: Lint and commit**

```bash
git add docs/specs/2026-10-03-app-store-build-design.md AGENTS.md README.md
git commit -m "docs: sandbox file access (milestone 5)"
```

---

### Task 12: Verification, and the owner's sandbox pass

- [ ] **Step 1: Everything green**

Run:
- the full test suite;
- the App Store compile;
- the lint gate;
- `git status`, which must be clean.

Expected: all tests pass (the 279 from before plus the ones this plan adds), both builds succeed, lint is clean.

- [ ] **Step 2: Build the App Store flavor to run**

```bash
xcodebuild -workspace "$HOME/MLXBits.xcworkspace" -scheme "MLXBits Image Studio (App Store)" \
  -configuration Debug-AppStore -derivedDataPath "$TMPDIR/image-studio-m5-derived" build 2>&1 | tail -5
```

This signs with Apple Development from `Config/Local.xcconfig` and bundles the runtime, so the keychain may prompt. The owner clicks Always Allow. Report the built app's path:

`$TMPDIR/image-studio-m5-derived/Build/Products/Debug-AppStore/MLXBits Image Studio.app`

- [ ] **Step 3: The owner runs the sandbox checklist**

These are spec §7's manual checks for this milestone. The owner runs them in the app; don't use CLI shortcuts. The app runs in its own container, so real data is safe.

1. **First run:**
   - library Choose…;
   - Skip for Now: the folder appears in Finder under Pictures;
   - the models step offers `~/.cache/huggingface`, and one click on Choose confirms;
   - with no cache, Continue keeps models in the container.
2. **Relaunch:**
   - the gallery and the models are still reachable, with no banner;
   - a generation saves into the library.
3. **LoRAs:**
   - one from an arbitrary folder, used again after a relaunch;
   - one added while the warm driver is already running (spec risk table);
   - with the warm driver already running: switch profile, use Change Folder…, and re-grant from the banner, generating after each (the image must save);
   - delete one in Finder: "Access lost" and Locate… appear, and a job using it fails with the spec's message.
4. **Source images:** img2img from outside the library, then a re-run after relaunch.
5. **Profiles:**
   - New Profile (picker only), switch, Change Folder, remove;
   - an external-drive library: unplug shows "not found", and replug clears the banner and rescans.
6. **Scenario Generator with local Gemma, on a fresh models folder:**
   - the download row shows progress;
   - closing the panel mid-download and reopening shows the download still going;
   - after it finishes, "Loading model…" then "Generating…";
   - LM Studio over the LAN still works.
7. **Model files:**
   - a Settings ▸ Models download into the models folder;
   - a model source override chosen with Browse…;
   - a typed folder path shows the lock hint.
8. **The upgrade path from TestFlight 0.16.0** (on a second Mac): the models step appears, and the library banner's Change Folder… re-grants the old library.

The DMG regression check is a DMG Debug build, launched only when the owner's own copy isn't running:
- Browse… fields still type-and-browse;
- the first local Gemma run shows the download row (or passes straight through when the model is cached).

- [ ] **Step 4: Final review and finishing**

Follow superpowers:executing-plans "Final Review": a whole-branch review on the most capable model, the plan's Review Focus included. Then superpowers:finishing-a-development-branch. The PR body says "Refs #18", not "Fixes": resume and cleanup of partial downloads stay open upstream. It has no AI attribution.
