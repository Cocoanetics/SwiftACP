import Foundation

// clack's lines around the prompts: `intro`, `outro`, `note` and `spinner`, as @clack/prompts
// 1.8.1 writes them.
extension ClackTerminal {
    /// `intro(title)`.
    func intro(_ title: String) {
        write(ClackText.style("gray", text: ClackSymbol.barStart) + "  " + title + "\n")
    }

    /// `outro(message)`.
    func outro(_ message: String) {
        let bar = ClackText.style("gray", text: ClackSymbol.bar)
        write(bar + "\n" + ClackText.style("gray", text: ClackSymbol.barEnd) + "  " + message + "\n\n")
    }

    /// `note(message, title)`: the message in a box under the title, its lines wrapped to fit.
    func note(_ message: String, title: String) {
        // `C` wraps it twice, the second time narrower by what formatting adds to a line: nothing,
        // with no `format` given.
        let lines = [""] + ClackText.wrap(message, columns: columns - 6).components(separatedBy: "\n") + [""]
        let titleWidth = ClackText.width(title)
        let inner = max(lines.map(ClackText.width).max() ?? 0, titleWidth) + 2
        let bar = ClackText.style("gray", text: ClackSymbol.bar)
        let body = lines.map { line in
            bar + "  " + line + String(repeating: " ", count: max(0, inner - ClackText.width(line))) + bar
        }.joined(separator: "\n")
        let rule = String(repeating: ClackSymbol.barHorizontal, count: max(inner - titleWidth - 1, 1))
        let top = ClackText.style("gray", text: rule + ClackSymbol.cornerTopRight)
        let bottom = ClackText.style(
            "gray",
            text: ClackSymbol.connectLeft + String(repeating: ClackSymbol.barHorizontal, count: inner + 2)
                + ClackSymbol.cornerBottomRight)
        write(bar + "\n" + ClackText.style("green", text: ClackSymbol.stepSubmit) + "  "
              + ClackText.style("reset", text: title) + " " + top + "\n" + body + "\n" + bottom + "\n")
    }
}

/// clack's `spinner`: a frame every 80 ms while the work it stands for runs, then the line it
/// ends with.
final class ClackSpinner: @unchecked Sendable {
    private let terminal: ClackTerminal
    /// The terminal's width when the spinner was made, which its frames are wrapped to.
    private let columns: Int
    /// Standard input, raw while the spinner runs if it is a terminal, as clack's `block` has it.
    private let standardInput = ClackTerminal()
    private let lock = NSLock()
    private var message = ""
    private var lastFrame: String?
    private var frame = 0
    private var dots = 0.0
    private var timer: DispatchSourceTimer?
    /// Finished: a tick the timer began before ``finish(_:failed:)`` draws nothing after it
    /// — clack's `clearInterval` stops every tick, one thread being all JavaScript has.
    private var stopped = false

    private static let frames = ClackSymbol.unicode
        ? ["\u{25D2}", "\u{25D0}", "\u{25D3}", "\u{25D1}"] : ["\u{2022}", "o", "O", "0"]
    private static let interval = ClackSymbol.unicode ? 80 : 120
    /// `isCI()`: a frame only when the message changes, with three dots.
    private static let continuousIntegration = ProcessInfo.processInfo.environment["CI"] == "true"

    init(on terminal: ClackTerminal) {
        self.terminal = terminal
        columns = terminal.columns
    }

    /// `start(message)`: the cursor hidden, a bar, and a frame every 80 ms from then on — the
    /// message without its trailing dots, which the frames count up instead.
    func start(_ message: String) {
        lock.withLock { self.message = String(message.reversed().drop { $0 == "." }.reversed()) }
        terminal.write("\u{1B}[?25l")
        standardInput.setRawMode(true)
        terminal.write(ClackText.style("gray", text: ClackSymbol.bar) + "\n")
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "clack.spinner"))
        let interval = DispatchTimeInterval.milliseconds(Self.interval)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    /// A frame, unless the spinner has finished.
    func tick() {
        lock.withLock {
            guard !stopped else { return }
            if Self.continuousIntegration, lastFrame == message { return }
            clearFrame()
            lastFrame = message
            let symbol = ClackText.style("magenta", text: Self.frames[frame])
            let shown = Self.continuousIntegration
                ? "..." : String(String(repeating: ".", count: Int(dots.rounded(.down))).prefix(3))
            terminal.write(ClackText.wrap("\(symbol)  \(message)\(shown)", columns: columns))
            frame = frame + 1 < Self.frames.count ? frame + 1 : 0
            dots = dots < 4 ? dots + 0.125 : 0
        }
    }

    /// `y`: the last frame taken back — counted as clack counts it, from the message alone
    /// (`p = s`), not from the frame drawn with its symbol and dots.
    private func clearFrame() {
        guard let lastFrame else { return }
        if Self.continuousIntegration { terminal.write("\n") }
        let lines = ClackText.wrap(lastFrame, columns: columns).components(separatedBy: "\n")
        if lines.count > 1 { terminal.write("\u{1B}[\(lines.count - 1)A") }
        terminal.write("\u{1B}[1G\u{1B}[J")
    }

    /// `stop(message)` and `error(message)`: the frames stopped, the last taken back, the message
    /// after the symbol that says how it went, and the cursor shown.
    func finish(_ message: String, failed: Bool) {
        lock.withLock {
            stopped = true
            timer?.cancel()
            timer = nil
            clearFrame()
            let symbol = failed
                ? ClackText.style("red", text: ClackSymbol.stepError)
                : ClackText.style("green", text: ClackSymbol.stepSubmit)
            terminal.write("\(symbol)  \(message)\n\u{1B}[?25h")
            standardInput.setRawMode(false)
        }
    }
}
