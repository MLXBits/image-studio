@testable import MLXBits_Image_Studio
import Testing

struct SourceImageFamilyTests {
    @Test func familiesWithASourceImageInput() {
        #expect(ModelFamily.flux.acceptsSourceImage)
        #expect(ModelFamily.krea2.acceptsSourceImage)
        #expect(ModelFamily.zimage.acceptsSourceImage)
        #expect(ModelFamily.qwen21.acceptsSourceImage)
    }

    @Test func familiesWithoutASourceImageInput() {
        #expect(!ModelFamily.ideogram4.acceptsSourceImage)
        #expect(!ModelFamily.seedvr2.acceptsSourceImage)
    }
}
