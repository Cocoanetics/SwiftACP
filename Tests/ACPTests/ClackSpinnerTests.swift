@testable import acpx
import Foundation
import Testing

/// skill-install's spinner (#294), as clack's draws.
struct ClackSpinnerTests {
    /// A tick the timer began before the spinner finished — waiting for its lock meanwhile —
    /// draws nothing after the finishing line.
    @Test func aLateTickDrawsNothingAfterTheEnd() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        defer { close(descriptors[0]) }
        let spinner = ClackSpinner(on: ClackTerminal(input: descriptors[0], output: descriptors[1]))
        spinner.start("Installing 1 target...")
        spinner.finish("Install complete.", failed: false)
        spinner.tick()
        close(descriptors[1])
        let shown = String(decoding: FileHandle(fileDescriptor: descriptors[0]).readDataToEndOfFile(), as: UTF8.self)
        #expect(shown.hasSuffix("Install complete.\n\u{1B}[?25h"), "\(shown.debugDescription)")
    }
}
