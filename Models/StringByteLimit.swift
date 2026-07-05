import SwiftUI

extension String {
    /// Longest prefix whose UTF-8 encoding fits in `maxBytes`, cut on a `Character`
    /// (grapheme) boundary so multi-byte characters and multi-scalar emoji are never split.
    /// Grapheme boundaries are a strict subset of the code-point boundaries the JS config
    /// engine truncates on, so a string clamped here is never re-truncated differently at
    /// encode time.
    func prefixFittingUTF8Bytes(_ maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard utf8.count > maxBytes else { return self }
        var used = 0
        var end = startIndex
        while end < endIndex {
            let next = index(after: end)
            used += self[end..<next].utf8.count
            if used > maxBytes { break }
            end = next
        }
        return String(self[..<end])
    }
}

extension View {
    /// Clamps `text` to at most `maxBytes` UTF-8 bytes, catching typed and pasted input
    /// alike. A `nil` limit leaves the field unrestricted. Writes back only when the value
    /// is actually over the limit so the `onChange` can't retrigger itself.
    func utf8ByteLimit(_ maxBytes: Int?, text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue) { _, newValue in
            guard let maxBytes, newValue.utf8.count > maxBytes else { return }
            text.wrappedValue = newValue.prefixFittingUTF8Bytes(maxBytes)
        }
    }
}
