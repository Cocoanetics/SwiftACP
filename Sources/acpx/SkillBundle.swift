import CryptoKit
import Foundation

/// The skill acpx bundles as skillflag packs a skill: its directory as a tar (`collectSkillEntries`,
/// `createTarStream`), which `--skill export` writes, `--skill list --json` digests and `--skill
/// install` installs from.
enum SkillBundle {
    /// An entry of the bundle: the skill's directory, or its `SKILL.md`.
    struct Entry {
        /// Its path in the tar, under the skill's id; a directory's ends with `/`.
        let name: String
        let isDirectory: Bool
        let mode: Int
        let content: Data
    }

    /// The bundle's entries for the skill as named by `id`, in the byte order skillflag sorts them
    /// in: the directory and its `SKILL.md`, with the modes an npm install of acpx gives them.
    static func entries(id: String) -> [Entry] {
        [
            Entry(name: "\(id)/", isDirectory: true, mode: 0o755, content: Data()),
            Entry(name: "\(id)/SKILL.md", isDirectory: false, mode: 0o644, content: Data(BundledSkill.markdown.utf8))
        ].sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }

    /// How many files the bundle holds.
    static var fileCount: Int {
        entries(id: BundledSkill.id).filter { !$0.isDirectory }.count
    }

    /// The bundle as tar-stream 3.2.1 packs it for skillflag: a ustar header for each entry — time
    /// 0, owner 0:0 without names — each file's content padded to 512 bytes, and two empty blocks.
    static func tar(id: String) -> Data {
        var tar = Data()
        for entry in entries(id: id) {
            tar.append(contentsOf: header(entry))
            tar.append(entry.content)
            let overflow = entry.content.count % 512
            if overflow > 0 { tar.append(Data(count: 512 - overflow)) }
        }
        tar.append(Data(count: 1024))
        return tar
    }

    /// `--skill list --json`'s digest of the bundle: `sha256:` and the hex of its SHA-256.
    static func digest(id: String) -> String {
        "sha256:" + SHA256.hash(data: tar(id: id)).map { String(format: "%02x", $0) }.joined()
    }

    /// tar-stream's `encode` of an entry's header, for a name that fits the header's 100 bytes.
    private static func header(_ entry: Entry) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)
        func write(_ text: String, at offset: Int) {
            block.replaceSubrange(offset..<(offset + text.utf8.count), with: text.utf8)
        }
        write(entry.name, at: 0)
        write(octal(entry.mode & 0o7777, digits: 6), at: 100)
        write(octal(0, digits: 6), at: 108)
        write(octal(0, digits: 6), at: 116)
        write(octal(entry.content.count, digits: 11), at: 124)
        write(octal(0, digits: 11), at: 136)
        block[156] = entry.isDirectory ? UInt8(ascii: "5") : UInt8(ascii: "0")
        write("ustar\0" + "00", at: 257)
        write(octal(0, digits: 6), at: 329)
        write(octal(0, digits: 6), at: 337)
        // The checksum counts its own field as spaces.
        let checksum = block.enumerated().reduce(0) { sum, byte in
            sum + ((148..<156).contains(byte.offset) ? 32 : Int(byte.element))
        }
        write(octal(checksum, digits: 6), at: 148)
        return block
    }

    /// tar-stream's `encodeOct`: `digits` octal digits, zero-padded, then a space.
    private static func octal(_ value: Int, digits: Int) -> String {
        let text = String(value, radix: 8)
        return String(repeating: "0", count: max(0, digits - text.count)) + text + " "
    }

    /// The skill's front matter, as skillflag reads it (``frontmatter(of:)``).
    static var frontmatter: [String: String] {
        frontmatter(of: BundledSkill.markdown)
    }

    /// The skill's summary in `--skill list`: its description, tabs and line breaks as spaces, trimmed.
    static var summary: String? {
        frontmatter["description"].map {
            String($0.map { $0 == "\t" || $0 == "\n" ? " " : $0 }).javaScriptTrimmed
        }
    }

    /// skillflag's `parseFrontmatter`: the `key: value` lines between a leading `---` line and the
    /// next — each key and value trimmed, a value's enclosing quotes dropped, and the lines without
    /// a `:`, key or value left out.
    static func frontmatter(of markdown: String) -> [String: String] {
        let pattern = #"^---\s*\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)),
              let block = Range(match.range(at: 1), in: markdown) else { return [:] }
        var fields: [String: String] = [:]
        for line in markdown[block].components(separatedBy: "\n") {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard !line.javaScriptTrimmed.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).javaScriptTrimmed
            let value = unquoted(String(line[line.index(after: colon)...]).javaScriptTrimmed)
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        return fields
    }

    /// `stripYamlQuotes`: a value in double or single quotes without them, trimmed.
    private static func unquoted(_ value: String) -> String {
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast()).javaScriptTrimmed
        }
        return value
    }
}
