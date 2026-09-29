import Foundation

/// clack's `multiselect`: options to tick with space, at least one to submit.
struct ClackMultiSelect: ClackPromptModel {
    struct Option: Equatable {
        let value: String
        let hint: String?
    }

    let message: String
    let options: [Option]
    private(set) var selected: [String]
    private var cursor = 0

    init(message: String, options: [Option], initialValues: [String]) {
        (self.message, self.options, selected) = (message, options, initialValues)
    }

    mutating func cursor(_ action: String) {
        switch action {
        case "left", "up": cursor = cursor - 1 < 0 ? options.count - 1 : cursor - 1
        case "down", "right": cursor = cursor + 1 >= options.count ? 0 : cursor + 1
        case "space":
            let value = options[cursor].value
            selected = selected.contains(value) ? selected.filter { $0 != value } : selected + [value]
        default: break
        }
    }

    /// `a` ticks every option, or none when all are; `i` ticks the others.
    mutating func key(_ key: ClackKey) {
        if key.name == "a" {
            selected = selected.count == options.count ? [] : options.map(\.value)
        } else if key.name == "i" {
            selected = options.map(\.value).filter { !selected.contains($0) }
        }
    }

    func invalid() -> String? {
        guard selected.isEmpty else { return nil }
        let space = ClackText.style("gray", "bgWhite", "inverse", text: " space ")
        let enter = ClackText.style(
            "gray", text: ClackText.style("bgWhite", text: ClackText.style("inverse", text: " enter ")))
        let press = ClackText.style("dim", text: "Press \(space) to select, \(enter) to submit")
        return "Please select at least one option.\n" + ClackText.style("reset", text: press)
    }

    /// An option as drawn in `style` (`u`).
    private func draw(_ option: Option, _ style: String) -> String {
        let label = option.value
        let hint = option.hint.map { " " + ClackText.style("dim", text: "(\($0))") } ?? ""
        let dimmed = ClackText.eachLine(label) { ClackText.style("dim", text: $0) }
        switch style {
        case "active": return ClackText.style("cyan", text: ClackSymbol.checkboxActive) + " \(label)\(hint)"
        case "selected": return ClackText.style("green", text: ClackSymbol.checkboxSelected) + " \(dimmed)\(hint)"
        case "cancelled": return ClackText.eachLine(label) { ClackText.style("strikethrough", "dim", text: $0) }
        case "active-selected": return ClackText.style("green", text: ClackSymbol.checkboxSelected) + " \(label)\(hint)"
        case "submitted": return dimmed
        default: return ClackText.style("dim", text: ClackSymbol.checkboxInactive) + " \(dimmed)"
        }
    }

    /// An option in the list: `g(option, active)`.
    private func listed(_ option: Option, active: Bool) -> String {
        let ticked = selected.contains(option.value)
        return draw(option, active && ticked ? "active-selected" : ticked ? "selected" : active ? "active" : "inactive")
    }

    func frame(_ state: ClackState, error: String, on terminal: ClackTerminal) -> String {
        let title = ClackText.wrap(
            message, on: terminal, prefix: ClackSymbol.bar(state) + "  ", first: ClackSymbol.step(state) + "  ")
        let header = ClackText.style("gray", text: ClackSymbol.bar) + "\n" + title + "\n"
        let chosen = options.filter { selected.contains($0.value) }
        switch state {
        case .submit:
            let list = chosen.map { draw($0, "submitted") }.joined(separator: ClackText.style("dim", text: ", "))
            let text = list.isEmpty ? ClackText.style("dim", text: "none") : list
            let bar = ClackText.style("gray", text: ClackSymbol.bar)
            return header + ClackText.wrap(text, on: terminal, prefix: bar + "  ")
        case .cancel:
            let list = chosen.map { draw($0, "cancelled") }.joined(separator: ClackText.style("dim", text: ", "))
            if list.javaScriptTrimmed.isEmpty { return header + ClackText.style("gray", text: ClackSymbol.bar) }
            let bar = ClackText.style("gray", text: ClackSymbol.bar)
            return header + ClackText.wrap(list, on: terminal, prefix: bar + "  ") + "\n" + bar
        case .error:
            let prefix = ClackText.style("yellow", text: ClackSymbol.bar) + "  "
            let lines = error.components(separatedBy: "\n").enumerated().map { index, line in
                index == 0
                    ? ClackText.style("yellow", text: ClackSymbol.barEnd) + "  " + ClackText.style("yellow", text: line)
                    : "   " + line
            }.joined(separator: "\n")
            let padding = header.components(separatedBy: "\n").count + lines.components(separatedBy: "\n").count + 1
            let list = limited(on: terminal, columnPadding: prefix.utf16.count, rowPadding: padding)
            return header + prefix + list.joined(separator: "\n" + prefix) + "\n" + lines + "\n"
        default:
            let prefix = ClackText.style("cyan", text: ClackSymbol.bar) + "  "
            let instructions = [
                ClackText.style("dim", text: "\u{2191}/\u{2193}") + " to navigate",
                ClackText.style("dim", text: "Space:") + " select",
                ClackText.style("dim", text: "Enter:") + " confirm"
            ]
            let footer = [
                prefix + instructions.joined(separator: " \u{2022} "), ClackText.style("cyan", text: ClackSymbol.barEnd)
            ]
            let padding = header.components(separatedBy: "\n").count + footer.count + 1
            let list = limited(on: terminal, columnPadding: prefix.utf16.count, rowPadding: padding)
            return header + prefix + list.joined(separator: "\n" + prefix) + "\n"
                + footer.joined(separator: "\n") + "\n"
        }
    }

    /// `limitOptions`: the options that fit the terminal's rows, the cursor's among them, with
    /// `...` for those above and below.
    private func limited(on terminal: ClackTerminal, columnPadding: Int, rowPadding: Int) -> [String] {
        let width = terminal.columns - columnPadding
        let available = max(terminal.rows - rowPadding, 0)
        let shown = max(available, 5)
        var start = 0
        if cursor >= shown - 3 { start = max(min(cursor - shown + 3, options.count - shown), 0) }
        var above = shown < options.count && start > 0
        var below = shown < options.count && start + shown < options.count
        let end = min(start + shown, options.count)
        var count = (above ? 1 : 0) + (below ? 1 : 0)
        let from = start + (above ? 1 : 0)
        let upTo = end - (below ? 1 : 0)
        var rows: [[String]] = []
        for index in stride(from: from, to: upTo, by: 1) {
            let lines = ClackText.wrap(listed(options[index], active: index == cursor), columns: width)
                .components(separatedBy: "\n")
            rows.append(lines)
            count += lines.count
        }
        if count > available {
            let (removedAbove, removedBelow) = Self.trim(
                rows, count: count, cursor: cursor - from, available: available, above: above, below: below)
            if removedAbove > 0 {
                above = true
                rows.removeFirst(removedAbove)
            }
            if removedBelow > 0 {
                below = true
                rows.removeLast(removedBelow)
            }
        }
        let ellipsis = ClackText.style("dim", text: "...")
        return (above ? [ellipsis] : []) + rows.flatMap { $0 } + (below ? [ellipsis] : [])
    }

    /// The rows to drop above and below the cursor's until the rest fit (`I`, and the branches
    /// of `limitOptions` that call it).
    private static func trim(
        _ rows: [[String]], count: Int, cursor: Int, available: Int, above: Bool, below: Bool
    ) -> (above: Int, below: Int) {
        func remove(from start: Int, to end: Int, lines: Int, room: Int, reversed: Bool) -> (lines: Int, removed: Int) {
            var (lines, removed) = (lines, 0)
            let indices = reversed
                ? Array(stride(from: end - 1, through: start, by: -1)) : Array(start..<max(start, end))
            for index in indices {
                if index < rows.count { lines -= rows[index].count }
                removed += 1
                if lines <= room { break }
            }
            return (lines, removed)
        }
        var (lines, removedAbove, removedBelow, room) = (count, 0, 0, available)
        if above {
            (lines, removedAbove) = remove(from: 0, to: cursor, lines: lines, room: room, reversed: false)
            if lines > room {
                if !below { room -= 1 }
                (lines, removedBelow) = remove(
                    from: cursor + 1, to: rows.count, lines: lines, room: room, reversed: true)
            }
        } else {
            if !below { room -= 1 }
            (lines, removedBelow) = remove(
                from: cursor + 1, to: rows.count, lines: lines, room: room, reversed: true)
            if lines > room {
                room -= 1
                (lines, removedAbove) = remove(from: 0, to: cursor, lines: lines, room: room, reversed: false)
            }
        }
        return (removedAbove, removedBelow)
    }
}

/// clack's `confirm`: yes or no.
struct ClackConfirm: ClackPromptModel {
    let message: String
    private(set) var value: Bool

    init(message: String, initialValue: Bool) {
        (self.message, value) = (message, initialValue)
    }

    /// Every cursor action turns it over, as `ConfirmPrompt` does — escape's too, before it cancels.
    mutating func cursor(_ action: String) {
        value.toggle()
    }

    var answersYesOrNo: Bool { true }

    mutating func answer(_ yes: Bool) {
        value = yes
    }

    func frame(_ state: ClackState, error: String, on terminal: ClackTerminal) -> String {
        let bar = ClackText.style("gray", text: ClackSymbol.bar)
        let title = ClackText.wrap(message, on: terminal, prefix: bar + "  ", first: ClackSymbol.step(state) + "  ")
        let header = bar + "\n" + title + "\n"
        let answer = value ? "Yes" : "No"
        switch state {
        case .submit:
            return header + bar + "  " + ClackText.style("dim", text: answer)
        case .cancel:
            return header + bar + "  " + ClackText.style("strikethrough", "dim", text: answer) + "\n" + bar
        default:
            let yes = value
                ? ClackText.style("green", text: ClackSymbol.radioActive) + " Yes"
                : ClackText.style("dim", text: ClackSymbol.radioInactive) + " " + ClackText.style("dim", text: "Yes")
            let no = value
                ? ClackText.style("dim", text: ClackSymbol.radioInactive) + " " + ClackText.style("dim", text: "No")
                : ClackText.style("green", text: ClackSymbol.radioActive) + " No"
            return header + ClackText.style("cyan", text: ClackSymbol.bar) + "  " + yes + " "
                + ClackText.style("dim", text: "/") + " " + no + "\n"
                + ClackText.style("cyan", text: ClackSymbol.barEnd) + "\n"
        }
    }
}
