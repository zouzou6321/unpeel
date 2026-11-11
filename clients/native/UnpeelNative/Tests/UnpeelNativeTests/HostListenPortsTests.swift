import XCTest
@testable import UnpeelNative

final class HostListenPortsTests: XCTestCase {
    func testDecodeReadsThePairingPortAndTheTerminalPort() throws {
        let json = """
        {"directPort":55921,"terminalStreamer":{"state":"live","port":61493}}
        """.data(using: .utf8)!
        let ports = HostListenPorts.decode(json)
        XCTAssertEqual(ports.pairing, 55921)
        XCTAssertEqual(ports.terminal, 61493)
    }

    func testDecodeIgnoresAMissingStreamer() throws {
        let json = #"{"directPort":55921}"#.data(using: .utf8)!
        let ports = HostListenPorts.decode(json)
        XCTAssertEqual(ports.pairing, 55921)
        XCTAssertNil(ports.terminal)
    }
}
