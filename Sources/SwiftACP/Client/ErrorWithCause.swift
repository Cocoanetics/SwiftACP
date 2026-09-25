import Foundation

/// An error that stands for another, saying what it came of: acpx's `cause`, which a
/// wrapped error keeps. Asking whether the connection ended
/// (``ACPAgentConnection/isConnectionClosed(_:)``) looks through it.
public protocol ErrorWithCause: Error {
    var cause: Error? { get }
}
