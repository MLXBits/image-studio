@testable import MLXBits_Image_Studio
import SwiftUI
import Testing

/// Covers `Binding.element(_:)`, the by-id row binding that replaced
/// `ForEach($array)` in the LoRA and Ideogram element lists (#54). A row whose
/// element was removed must not trap when its text field reads it once more.
struct BindingElementTests {
    private struct Row: Identifiable, Equatable {
        let id: Int
        var value: String
    }

    /// An array binding backed by a box, standing in for a view's `@State`.
    private final class Storage {
        var rows: [Row]
        var binding: Binding<[Row]> {
            Binding(get: { self.rows }, set: { self.rows = $0 })
        }

        init(_ rows: [Row]) {
            self.rows = rows
        }
    }

    @Test func readsAndWritesTheElementWithTheSameID() {
        let storage = Storage([Row(id: 1, value: "a"), Row(id: 2, value: "b")])
        let row = storage.binding.element(storage.rows[1])
        #expect(row.wrappedValue.value == "b")
        row.wrappedValue.value = "c"
        #expect(storage.rows == [Row(id: 1, value: "a"), Row(id: 2, value: "c")])
    }

    @Test func followsTheElementWhenRowsAreReordered() {
        let storage = Storage([Row(id: 1, value: "a"), Row(id: 2, value: "b")])
        let row = storage.binding.element(storage.rows[0])
        storage.rows.swapAt(0, 1)
        row.wrappedValue.value = "z"
        #expect(storage.rows == [Row(id: 2, value: "b"), Row(id: 1, value: "z")])
    }

    @Test func removedElementReadsItsLastValueAndDropsWrites() {
        let storage = Storage([Row(id: 1, value: "a"), Row(id: 2, value: "b")])
        let row = storage.binding.element(storage.rows[1])
        storage.rows.removeAll { $0.id == 2 }
        #expect(row.wrappedValue == Row(id: 2, value: "b"))
        row.wrappedValue.value = "c"
        #expect(storage.rows == [Row(id: 1, value: "a")])
    }
}
