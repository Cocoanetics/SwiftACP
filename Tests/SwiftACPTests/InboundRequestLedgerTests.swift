@testable import SwiftACP
import Foundation
import Testing

/// The per-session count of the agent's unanswered requests that a turn waits on
/// before it ends.
@Suite(.timeLimit(.minutes(1)))
struct InboundRequestLedgerTests {
    @Test func aSessionWithNothingInFlightIsIdleAtOnce() async {
        let ledger = InboundRequestLedger()
        await ledger.waitUntilIdle("s")
        ledger.arrived("s")
        ledger.finished("s")
        await ledger.waitUntilIdle("s")
    }

    /// The wait ends with the *last* answer, and only its own session's requests count.
    @Test func theWaitEndsWhenTheSessionsLastRequestIsAnswered() async {
        let ledger = InboundRequestLedger()
        let waiting = Signal()
        ledger.setOnWait { _ in waiting.fire() }
        ledger.arrived("s")
        ledger.arrived("s")
        ledger.arrived("other")

        let done = Signal()
        let waiter = Task {
            await ledger.waitUntilIdle("s")
            done.fire()
        }
        await waiting.wait()
        ledger.finished("s")
        #expect(!done.isFired)
        ledger.finished("s")  // the other session's request is still open, and irrelevant
        await waiter.value
        #expect(done.isFired)
    }

    @Test func theSessionIsReadFromTheRequestsParams() {
        #expect(InboundRequestLedger.sessionId(of: .object(["sessionId": .string("s-1")])) == "s-1")
        #expect(InboundRequestLedger.sessionId(of: .object(["path": .string("/x")])) == nil)
        #expect(InboundRequestLedger.sessionId(of: nil) == nil)
    }
}
