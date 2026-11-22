@testable import MLXBits_Image_Studio
import Testing

/// The Models window's teaching copy: every shipped model explains itself.
struct ModelGuideTests {
    @Test func everyModelHasABlurbAndTags() {
        for model in FluxModelVariant.allModels {
            #expect(!model.guide.blurb.isEmpty, "\(model)")
            #expect((1 ... 4).contains(model.guide.greatAt.count), "\(model)")
        }
    }

    @Test func blurbsAreDistinct() {
        #expect(Set(FluxModelVariant.allModels.map(\.guide.blurb)).count == FluxModelVariant.allModels.count)
    }

    @Test func ideogramNotesItsGatedRepos() {
        #expect(FluxModelVariant.ideogram4.guide.note?.contains("token") == true)
    }
}
