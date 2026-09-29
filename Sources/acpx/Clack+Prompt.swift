import Foundation

// The prompts skillflag's install wizard asks with, as @clack/core 1.5.1 runs them and
// @clack/prompts 1.8.1 draws them: a frame for the prompt's state, redrawn — only the lines that
// changed — as each key changes it, until a key submits or cancels it (#294).

/// A prompt's state (`Prompt.state`).
enum ClackState: String {
    case initial, active, submit, cancel, error
}

/// clack's symbols: Unicode, or plain characters on a Linux console (`isUnicodeSupported`).
enum ClackSymbol {
    static let unicode = ProcessInfo.processInfo.environment["TERM"] != "linux"

    private static func pick(_ unicode: String, _ plain: String) -> String { Self.unicode ? unicode : plain }

    static let stepActive = pick("\u{25C6}", "*")
    static let stepCancel = pick("\u{25A0}", "x")
    static let stepError = pick("\u{25B2}", "x")
    static let stepSubmit = pick("\u{25C7}", "o")
    static let barStart = pick("\u{250C}", "T")
    static let bar = pick("\u{2502}", "|")
    static let barEnd = pick("\u{2514}", "\u{2014}")
    static let radioActive = pick("\u{25CF}", ">")
    static let radioInactive = pick("\u{25CB}", " ")
    static let checkboxActive = pick("\u{25FB}", "[\u{2022}]")
    static let checkboxSelected = pick("\u{25FC}", "[+]")
    static let checkboxInactive = pick("\u{25FB}", "[ ]")
    static let barHorizontal = pick("\u{2500}", "-")
    static let cornerTopRight = pick("\u{256E}", "+")
    static let connectLeft = pick("\u{251C}", "+")
    static let cornerBottomRight = pick("\u{256F}", "+")

    /// `symbol(state)`.
    static func step(_ state: ClackState) -> String {
        switch state {
        case .initial, .active: ClackText.style("cyan", text: stepActive)
        case .cancel: ClackText.style("red", text: stepCancel)
        case .error: ClackText.style("yellow", text: stepError)
        case .submit: ClackText.style("green", text: stepSubmit)
        }
    }

    /// `symbolBar(state)`.
    static func bar(_ state: ClackState) -> String {
        switch state {
        case .initial, .active: ClackText.style("cyan", text: bar)
        case .cancel: ClackText.style("red", text: bar)
        case .error: ClackText.style("yellow", text: bar)
        case .submit: ClackText.style("green", text: bar)
        }
    }
}

/// What a prompt is: how it draws, and what keys do to it.
protocol ClackPromptModel {
    /// The frame for `state`, with the validation `error` it is in.
    func frame(_ state: ClackState, error: String, on terminal: ClackTerminal) -> String
    /// A cursor action — `up`, `down`, `left`, `right`, `space`, `enter` or `cancel`.
    mutating func cursor(_ action: String)
    /// A key, whatever it is (a multiselect's `a` and `i`).
    mutating func key(_ key: ClackKey)
    /// Whether `y` and `n` answer it (a confirm).
    var answersYesOrNo: Bool { get }
    mutating func answer(_ yes: Bool)
    /// Why return does not submit it; `nil` when it does.
    func invalid() -> String?
}

extension ClackPromptModel {
    mutating func key(_ key: ClackKey) {}
    var answersYesOrNo: Bool { false }
    mutating func answer(_ yes: Bool) {}
    func invalid() -> String? { nil }
}

/// A prompt running: clack's `Prompt`.
struct ClackPrompt<Model: ClackPromptModel> {
    var model: Model
    let terminal: ClackTerminal
    private var state = ClackState.initial
    private var error = ""
    private var previousFrame = ""

    /// `settings.aliases`.
    private static var aliases: [String: String] {
        ["k": "up", "j": "down", "h": "left", "l": "right", "\u{3}": "cancel", "escape": "cancel"]
    }

    /// `settings.actions`.
    private static var actions: Set<String> { ["up", "down", "left", "right", "space", "enter", "cancel"] }

    init(_ model: Model, on terminal: ClackTerminal) {
        self.model = model
        self.terminal = terminal
    }

    /// `prompt()`: the model once a key submits it, `nil` once one cancels it — or the input ends.
    mutating func run() -> Model? {
        terminal.setRawMode(true)
        render()
        while let key = terminal.readKey() {
            if let outcome = handle(key) { return outcome ? model : nil }
        }
        terminal.setRawMode(false)
        return nil
    }

    /// `onKeypress`: whether the key ended the prompt, submitted or cancelled; `nil` while it goes on.
    private mutating func handle(_ key: ClackKey) -> Bool? {
        var closed = false
        if state == .error { state = .active }
        if let name = key.name {
            if let alias = Self.aliases[name] { model.cursor(alias) }
            if Self.actions.contains(name) { model.cursor(name) }
        }
        if model.answersYesOrNo, let text = key.text, ["y", "n"].contains(text.lowercased()) {
            // A confirm's `confirm` event: it closes the prompt there and then — and the key goes on
            // to render and close it again, as clack's does.
            terminal.write("\u{1B}[1A")
            model.answer(text.lowercased() == "y")
            state = .submit
            close(showingCursor: true)
            closed = true
        }
        if !closed { model.key(key) }
        if key.name == "return" {
            if let message = model.invalid() {
                error = message
                state = .error
            }
            if state != .error { state = .submit }
        }
        let cancels = [key.text, key.name, key.sequence].contains { $0.flatMap { Self.aliases[$0] } == "cancel" }
        if cancels { state = .cancel }
        render()
        guard state == .submit || state == .cancel else { return nil }
        close(showingCursor: !closed)
        return state == .submit
    }

    /// `close()`: the line ended, the terminal cooked again, and the cursor shown — unless a
    /// close before already told the prompt's caller.
    private func close(showingCursor: Bool) {
        terminal.write("\n")
        terminal.setRawMode(false)
        if showingCursor { terminal.write("\u{1B}[?25h") }
    }

    /// The frame, wrapped as `wrapAnsi(frame, process.stdout.columns)` wraps it.
    private func wrapped(_ frame: String) -> String {
        ClackText.wrap(frame, columns: terminal.stdoutColumns ?? .max)
    }

    /// `render()`: the frame drawn, or only its lines that changed.
    private mutating func render() {
        let frame = wrapped(model.frame(state, error: error, on: terminal))
        guard frame != previousFrame else { return }
        guard state != .initial else {
            terminal.write("\u{1B}[?25l" + frame)
            state = .active
            previousFrame = frame
            return
        }
        let before = previousFrame.components(separatedBy: "\n")
        let after = frame.components(separatedBy: "\n")
        let changed = (0..<max(before.count, after.count)).filter { index in
            (index < before.count ? before[index] : nil) != (index < after.count ? after[index] : nil)
        }
        let rows = terminal.rows
        // `restoreCursor`: to the frame's first line.
        terminal.write(Self.move(-999, -(wrapped(previousFrame).components(separatedBy: "\n").count - 1)))
        let hiddenAfter = max(0, after.count - rows)
        let hiddenBefore = max(0, before.count - rows)
        guard var first = changed.first(where: { $0 >= hiddenAfter }) else {
            previousFrame = frame
            return
        }
        if changed.count == 1 {
            terminal.write(Self.move(0, first - hiddenBefore) + "\u{1B}[2K\u{1B}[G" + after[first])
            terminal.write(Self.move(0, after.count - first - 1))
        } else {
            if hiddenAfter < hiddenBefore {
                first = hiddenAfter
            } else if first - hiddenBefore > 0 {
                terminal.write(Self.move(0, first - hiddenBefore))
            }
            terminal.write("\u{1B}[J" + after[first...].joined(separator: "\n"))
        }
        previousFrame = frame
    }

    /// sisteransi's `cursor.move(x, y)`.
    static func move(_ columns: Int, _ lines: Int) -> String {
        var text = ""
        if columns < 0 { text += "\u{1B}[\(-columns)D" } else if columns > 0 { text += "\u{1B}[\(columns)C" }
        if lines < 0 { text += "\u{1B}[\(-lines)A" } else if lines > 0 { text += "\u{1B}[\(lines)B" }
        return text
    }
}

// MARK: - Drawing helpers

extension ClackText {
    /// `wrapTextWithPrefix(output, text, prefix, first, last)`: the text wrapped to the terminal's
    /// width less the prefix's length — its escape codes counted, as clack counts them — and its
    /// lines led by `first`, `prefix` and `last`.
    static func wrap(
        _ text: String, on terminal: ClackTerminal, prefix: String, first: String? = nil, last: String? = nil,
        styling: ((String) -> String)? = nil
    ) -> String {
        let lines = wrap(text, columns: terminal.columns - prefix.utf16.count).components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            let styled = styling?(line) ?? line
            if index == 0 { return (first ?? prefix) + styled }
            return (index == lines.count - 1 ? last ?? prefix : prefix) + styled
        }.joined(separator: "\n")
    }

    /// `m(text, style)`: `style` on each line of the text.
    static func eachLine(_ text: String, _ style: (String) -> String) -> String {
        text.components(separatedBy: "\n").map(style).joined(separator: "\n")
    }
}
