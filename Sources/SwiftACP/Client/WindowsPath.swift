import Foundation

/// Node's `path.win32`, as acpx's Windows command resolution uses it (`lib/path.js`, Node
/// v25.9.0): `resolve`, `normalize`, `join`, `isAbsolute` and `extname`. It works on UTF-16 code
/// units, as JavaScript's strings do, and on every platform, so the resolution is checked away
/// from Windows too (`acpx-windows-spawn.json`, #265).
enum WindowsPath {
    private static let slash = UInt16(UInt8(ascii: "/"))
    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let dot = UInt16(UInt8(ascii: "."))
    private static let colon = UInt16(UInt8(ascii: ":"))
    private static let question = UInt16(UInt8(ascii: "?"))

    /// `CON`, `NUL`, `COM1` and the rest: names Windows takes for devices.
    private static let reservedNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for suffix in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "\u{B9}", "\u{B2}", "\u{B3}"] {
            names.insert("COM" + suffix)
            names.insert("LPT" + suffix)
        }
        return names
    }()

    static func isSeparator(_ code: UInt16) -> Bool {
        code == slash || code == backslash
    }

    private static func isDriveLetter(_ code: UInt16) -> Bool {
        (65...90).contains(code) || (97...122).contains(code)
    }

    static func isAbsolute(_ path: String) -> Bool {
        let units = Array(path.utf16)
        guard let first = units.first else { return false }
        return isSeparator(first)
            || (units.count > 2 && isDriveLetter(first) && units[1] == colon && isSeparator(units[2]))
    }

    /// The last component's extension, its dot included: `""` for none, `"."` for a trailing dot.
    static func extname(_ path: String) -> String {
        let units = Array(path.utf16)
        let start = units.count >= 2 && units[1] == colon && isDriveLetter(units[0]) ? 2 : 0
        var startPart = start
        var startDot = -1
        var end = -1
        var matchedSlash = true
        // What came before the first dot: 0 nothing, 1 dots only, -1 anything else.
        var preDotState = 0
        for index in stride(from: units.count - 1, through: start, by: -1) {
            let code = units[index]
            if isSeparator(code) {
                if !matchedSlash {
                    startPart = index + 1
                    break
                }
                continue
            }
            if end == -1 {
                matchedSlash = false
                end = index + 1
            }
            if code == dot {
                if startDot == -1 { startDot = index } else if preDotState != 1 { preDotState = 1 }
            } else if startDot != -1 {
                preDotState = -1
            }
        }
        let isDotDot = preDotState == 1 && startDot == end - 1 && startDot == startPart + 1
        guard startDot != -1, end != -1, preDotState != 0, !isDotDot else { return "" }
        return string(units[startDot..<end])
    }

    /// The path without its last component: its root as it is when that is all there is.
    static func dirname(_ path: String) -> String {
        let units = Array(path.utf16)
        guard units.count > 1 else { return units.first.map(isSeparator) == true ? path : "." }
        var rootEnd = -1
        var offset = 0
        if isSeparator(units[0]) {
            rootEnd = 1
            offset = 1
            if isSeparator(units[1]), let unc = uncParts(of: units) {
                // A UNC root alone is its own directory; after one, the separator is the root's.
                if unc.second.upperBound == units.count { return path }
                rootEnd = unc.second.upperBound + 1
                offset = rootEnd
            }
        } else if isDriveLetter(units[0]), units[1] == colon {
            rootEnd = units.count > 2 && isSeparator(units[2]) ? 3 : 2
            offset = rootEnd
        }
        var end = -1
        var matchedSlash = true
        for index in stride(from: units.count - 1, through: offset, by: -1) {
            if isSeparator(units[index]) {
                if !matchedSlash {
                    end = index
                    break
                }
            } else {
                matchedSlash = false
            }
        }
        if end == -1 {
            guard rootEnd != -1 else { return "." }
            end = rootEnd
        }
        return string(units[..<end])
    }

    static func join(_ parts: String...) -> String {
        let parts = parts.filter { !$0.isEmpty }
        guard let first = parts.first.map({ Array($0.utf16) }) else { return "." }
        var joined = Array(parts.joined(separator: "\\").utf16)
        // Leading separators collapse to one, unless the first part names a UNC root.
        var slashCount = 0
        var namesUNC = false
        if isSeparator(first[0]) {
            slashCount = 1
            if first.count > 1, isSeparator(first[1]) {
                slashCount = 2
                if first.count > 2 {
                    if isSeparator(first[2]) { slashCount = 3 } else { namesUNC = true }
                }
            }
        }
        if !namesUNC {
            while slashCount < joined.count, isSeparator(joined[slashCount]) { slashCount += 1 }
            if slashCount >= 2 { joined = [backslash] + joined[slashCount...] }
        }
        let segments = joined.split(separator: backslash)
        let namesDevice = segments.contains { segment in
            guard let colonIndex = segment.firstIndex(of: colon) else { return false }
            return isReservedName(Array(segment), colonIndex - segment.startIndex)
        }
        guard !namesDevice else { return string(joined.map { $0 == slash ? backslash : $0 }) }
        return normalize(string(joined))
    }

    /// `path.win32.resolve(...paths)`. Run out of paths without an absolute one, it takes
    /// `processDirectory`, as Node takes `process.cwd()`.
    static func resolve(
        _ paths: [String], processDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String {
        var resolvedDevice: [UInt16] = []
        var resolvedTail: [UInt16] = []
        var resolvedAbsolute = false
        for index in stride(from: paths.count - 1, through: -1, by: -1) {
            var path: [UInt16]
            if index >= 0 {
                path = Array(paths[index].utf16)
                if path.isEmpty { continue }
            } else {
                path = Array(processDirectory.utf16)
                // A drive's own directory is not known here, so a directory on another drive
                // gives the drive's root, as Node's does when `=D:` is not set.
                if !resolvedDevice.isEmpty, lowercased(path.prefix(2)) != lowercased(resolvedDevice),
                   path.count > 2, path[2] == backslash {
                    path = resolvedDevice + [backslash]
                }
            }
            let root = resolvingRoot(of: path)
            let device = root.device ?? []
            if !device.isEmpty {
                if resolvedDevice.isEmpty {
                    resolvedDevice = device
                } else if lowercased(device) != lowercased(resolvedDevice) {
                    // On another device, so not a part of this path.
                    continue
                }
            }
            if resolvedAbsolute {
                if !resolvedDevice.isEmpty { break }
            } else {
                resolvedTail = Array(path[root.end...]) + [backslash] + resolvedTail
                resolvedAbsolute = root.isAbsolute
                if root.isAbsolute, !resolvedDevice.isEmpty { break }
            }
        }
        resolvedTail = normalizeString(resolvedTail, allowAboveRoot: !resolvedAbsolute)
        if resolvedAbsolute { return string(resolvedDevice) + "\\" + string(resolvedTail) }
        let relative = string(resolvedDevice) + string(resolvedTail)
        return relative.isEmpty ? "." : relative
    }

    static func normalize(_ path: String) -> String {
        let units = Array(path.utf16)
        guard units.count > 1 else { return units.isEmpty ? "." : (units[0] == slash ? "\\" : path) }
        let root: Root
        switch normalizingRoot(of: units) {
        case .root(let found): root = found
        case .uncRootOnly(let normalized): return normalized
        }
        let len = units.count
        var tail = root.end < len ? normalizeString(Array(units[root.end...]), allowAboveRoot: !root.isAbsolute) : []
        if tail.isEmpty, !root.isAbsolute { tail = [dot] }
        if !tail.isEmpty, isSeparator(units[len - 1]) { tail.append(backslash) }
        let colonIndex = units.firstIndex(of: colon)
        if !root.isAbsolute, root.device == nil, let colonIndex,
           looksAbsolute(tail: tail, colonIndex: colonIndex, in: units) {
            // Not taken for an absolute path (CVE-2024-36139).
            return ".\\" + string(tail)
        }
        if isReservedName(units, colonIndex ?? -1) { return ".\\" + string(root.device ?? []) + string(tail) }
        guard let device = root.device else { return root.isAbsolute ? "\\" + string(tail) : string(tail) }
        return string(device) + (root.isAbsolute ? "\\" : "") + string(tail)
    }

    // MARK: - Roots

    /// A path's root: its device, if it names one, where the root ends, and whether it is absolute.
    private struct Root {
        var device: [UInt16]?
        var end = 0
        var isAbsolute = false
    }

    /// The root as `resolve` reads it, for a path of one code unit or more.
    private static func resolvingRoot(of path: [UInt16]) -> Root {
        let code = path[0]
        if path.count == 1 { return isSeparator(code) ? Root(end: 1, isAbsolute: true) : Root() }
        if isSeparator(code) {
            guard isSeparator(path[1]) else { return Root(end: 1, isAbsolute: true) }
            guard let unc = uncParts(of: path) else { return Root(isAbsolute: true) }
            if unc.first.elementsEqual([dot]) || unc.first.elementsEqual([question]) {
                return Root(device: [backslash, backslash] + unc.first, end: 4, isAbsolute: true)
            }
            let device = [backslash, backslash] + unc.first + [backslash] + path[unc.second]
            return Root(device: device, end: unc.second.upperBound, isAbsolute: true)
        }
        if isDriveLetter(code), path[1] == colon {
            let isAbsolute = path.count > 2 && isSeparator(path[2])
            return Root(device: Array(path[0..<2]), end: isAbsolute ? 3 : 2, isAbsolute: isAbsolute)
        }
        return Root()
    }

    private enum NormalizingRoot {
        case root(Root)
        /// A UNC root with nothing after it, normalized.
        case uncRootOnly(String)
    }

    /// The root as `normalize` reads it, for a path of two code units or more.
    private static func normalizingRoot(of path: [UInt16]) -> NormalizingRoot {
        let code = path[0]
        if isSeparator(code) {
            guard isSeparator(path[1]) else { return .root(Root(end: 1, isAbsolute: true)) }
            guard let unc = uncParts(of: path) else { return .root(Root(isAbsolute: true)) }
            if unc.first.elementsEqual([dot]) || unc.first.elementsEqual([question]) {
                return .root(deviceNamespaceRoot(of: path, prefix: unc.first))
            }
            if unc.second.upperBound == path.count {
                return .uncRootOnly("\\\\" + string(unc.first) + "\\" + string(path[unc.second]) + "\\")
            }
            let device = [backslash, backslash] + unc.first + [backslash] + path[unc.second]
            return .root(Root(device: device, end: unc.second.upperBound, isAbsolute: true))
        }
        guard let colonIndex = path.firstIndex(of: colon), colonIndex > 0 else { return .root(Root()) }
        if isDriveLetter(code), colonIndex == 1 {
            let isAbsolute = path.count > 2 && isSeparator(path[2])
            return .root(Root(device: Array(path[0..<2]), end: isAbsolute ? 3 : 2, isAbsolute: isAbsolute))
        }
        if isReservedName(path, colonIndex) {
            return .root(Root(device: Array(path[...colonIndex]), end: colonIndex + 1))
        }
        return .root(Root())
    }

    /// `\\.\` or `\\?\`, taking a device name after it (`\\?\COM1:`) into the root.
    private static func deviceNamespaceRoot(of path: [UInt16], prefix: ArraySlice<UInt16>) -> Root {
        let colonIndex = path.firstIndex(of: colon) ?? -1
        let possibleDevice = jsSlice(path, from: 4, to: colonIndex + 1)
        if isReservedName(possibleDevice, possibleDevice.count - 1) {
            let device = Array("\\\\?\\".utf16) + possibleDevice
            return Root(device: device, end: 4 + possibleDevice.count, isAbsolute: true)
        }
        return Root(device: [backslash, backslash] + prefix, end: 4, isAbsolute: true)
    }

    /// The `\\server\share` a path starts with, as Node matches it: the first part, and the
    /// range of the second.
    private static func uncParts(of path: [UInt16]) -> (first: ArraySlice<UInt16>, second: Range<Int>)? {
        let len = path.count
        var index = 2
        while index < len, !isSeparator(path[index]) { index += 1 }
        guard index < len, index != 2 else { return nil }
        let first = path[2..<index]
        let separatorsStart = index
        while index < len, isSeparator(path[index]) { index += 1 }
        guard index < len, index != separatorsStart else { return nil }
        let secondStart = index
        while index < len, !isSeparator(path[index]) { index += 1 }
        return (first, secondStart..<index)
    }

    /// Whether a relative tail could pass for an absolute path: a drive, or a colon that ends a
    /// component.
    private static func looksAbsolute(tail: [UInt16], colonIndex: Int, in path: [UInt16]) -> Bool {
        if tail.count >= 2, isDriveLetter(tail[0]), tail[1] == colon { return true }
        var next: Int? = colonIndex
        while let index = next {
            if index == path.count - 1 || isSeparator(path[index + 1]) { return true }
            next = path[(index + 1)...].firstIndex(of: colon)
        }
        return false
    }

    /// Node's `isWindowsReservedName`: what comes before `colonIndex`, sliced as JavaScript
    /// slices, is a device's name. A `colonIndex` of `-1` leaves off the last code unit.
    private static func isReservedName(_ path: [UInt16], _ colonIndex: Int) -> Bool {
        reservedNames.contains(string(jsSlice(path, from: 0, to: colonIndex)).uppercased())
    }

    /// `String.prototype.slice`: a negative end counts from the end.
    private static func jsSlice(_ units: [UInt16], from start: Int, to end: Int) -> [UInt16] {
        let upper = end < 0 ? max(0, units.count + end) : min(end, units.count)
        return start < upper ? Array(units[start..<upper]) : []
    }

    // MARK: - Components

    /// Node's `normalizeString`: `.` and `..` resolved, separators made single backslashes.
    private static func normalizeString(_ path: [UInt16], allowAboveRoot: Bool) -> [UInt16] {
        var result: [UInt16] = []
        var lastSegmentLength = 0
        var lastSlash = -1
        var dots = 0
        var code: UInt16 = 0
        for index in 0...path.count {
            if index < path.count {
                code = path[index]
            } else if isSeparator(code) {
                break
            } else {
                code = slash
            }
            if isSeparator(code) {
                if lastSlash == index - 1 || dots == 1 {
                    // An empty component, or `.`.
                } else if dots == 2 {
                    if dropLastSegment(&result, &lastSegmentLength) {
                        lastSlash = index
                        dots = 0
                        continue
                    }
                    if allowAboveRoot {
                        result += result.isEmpty ? [dot, dot] : [backslash, dot, dot]
                        lastSegmentLength = 2
                    }
                } else {
                    if !result.isEmpty { result.append(backslash) }
                    result += path[(lastSlash + 1)..<index]
                    lastSegmentLength = index - lastSlash - 1
                }
                lastSlash = index
                dots = 0
            } else if code == dot, dots != -1 {
                dots += 1
            } else {
                dots = -1
            }
        }
        return result
    }

    /// For a `..`: the last segment taken off, unless there is none, or it is a `..` itself.
    private static func dropLastSegment(_ result: inout [UInt16], _ lastSegmentLength: inout Int) -> Bool {
        let endsInDotDot = result.count >= 2 && lastSegmentLength == 2
            && result[result.count - 1] == dot && result[result.count - 2] == dot
        guard !endsInDotDot else { return false }
        if result.count > 2 {
            let lastSlashIndex = result.count - lastSegmentLength - 1
            if lastSlashIndex == -1 {
                result = []
                lastSegmentLength = 0
            } else {
                result = Array(result[..<lastSlashIndex])
                lastSegmentLength = result.count - 1 - (result.lastIndex(of: backslash) ?? -1)
            }
            return true
        }
        guard !result.isEmpty else { return false }
        result = []
        lastSegmentLength = 0
        return true
    }

    private static func lowercased(_ units: some Collection<UInt16>) -> String {
        string(units).lowercased()
    }

    private static func string(_ units: some Collection<UInt16>) -> String {
        String(decoding: units, as: UTF16.self)
    }
}
