import SwiftACP

/// Whether `python3` is available for the bundled `mock-agent.py` fixture. Gates
/// the daemon tests that spawn the mock agent.
let mockPythonAvailable = AgentRegistry.which("python3") != nil
