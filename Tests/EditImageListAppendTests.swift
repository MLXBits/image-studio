@testable import MLXBits_Image_Studio
import Testing

struct EditImageListAppendTests {
    @Test func skipsDuplicatesByAdoptedPath() {
        var paths = ["/lib/a.png"]
        EditImageListView
            .appendAdopted(["/x/a.png", "/x/b.png"], to: &paths, maxCount: nil) { "/lib/" + String($0.split(separator: "/").last ?? "") }
        #expect(paths == ["/lib/a.png", "/lib/b.png"])
    }

    @Test func capChecksBeforeAdopting() {
        var paths = ["/a"]
        var adoptCalls = 0
        EditImageListView.appendAdopted(["/b", "/c", "/d"], to: &paths, maxCount: 2) { adoptCalls += 1; return $0 }
        #expect(paths == ["/a", "/b"])
        #expect(adoptCalls == 1)
    }

    @Test func fullListNeverAdopts() {
        var paths = ["/a"]
        var adoptCalls = 0
        EditImageListView.appendAdopted(["/b"], to: &paths, maxCount: 1) { adoptCalls += 1; return $0 }
        #expect(paths == ["/a"])
        #expect(adoptCalls == 0)
    }
}
