import SwiftUI

extension Binding {
    /// A binding to one element of an array, found by id on every read and write.
    ///
    /// Use it in place of `ForEach($array) { $row in … }`, which binds each row
    /// to `array[i]` by position. When a row is removed, a text field in it can
    /// read its binding once more in the same update, after the array has shrunk,
    /// and the subscript traps (#54). This binding returns the row's last known
    /// value instead, and drops writes to a row that is gone.
    func element<Element: Identifiable>(_ element: Element) -> Binding<Element> where Value == [Element] {
        Binding<Element>(
            get: { wrappedValue.first { $0.id == element.id } ?? element },
            set: { newValue in
                guard let index = wrappedValue.firstIndex(where: { $0.id == element.id }) else { return }
                wrappedValue[index] = newValue
            }
        )
    }
}
