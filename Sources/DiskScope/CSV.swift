import Foundation

/// Minimal RFC 4180 CSV writer.
///
/// Fields containing a comma, quote, CR or LF (or leading/trailing spaces) are quoted, with inner
/// quotes doubled; rows end with CRLF. Text that a spreadsheet would run as a formula — starting
/// with = + - @, a tab or a CR — gets a leading apostrophe, so opening an export of untrusted
/// file names in Excel or Numbers can't execute anything ("CSV injection").
enum CSV {
    private static let formulaStarts: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

    /// A text field. Use `number` for numeric values (they're never neutralised).
    static func field(_ text: String) -> String {
        var value = text
        if let first = value.unicodeScalars.first, formulaStarts.contains(first) { value = "'" + value }
        let needsQuotes = value.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func number<T: BinaryInteger>(_ n: T) -> String { String(n) }

    /// One row of text fields, CRLF-terminated.
    static func row(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",") + "\r\n"
    }

    /// One row of already-encoded fields (from `field` / `number`), CRLF-terminated.
    static func row(encoded fields: [String]) -> String {
        fields.joined(separator: ",") + "\r\n"
    }

    /// A header row followed by text rows.
    static func document(header: [String], rows: [[String]]) -> String {
        row(header) + rows.map { row($0) }.joined()
    }
}
