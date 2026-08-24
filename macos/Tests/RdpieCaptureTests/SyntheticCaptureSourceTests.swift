import XCTest
@testable import RdpieCapture

final class SyntheticCaptureSourceTests: XCTestCase {

    func testEmitsFramesWithTheConfiguredGeometry() async throws {
        let source = SyntheticCaptureSource()
        try source.start(configuration: CaptureConfiguration(width: 4, height: 2, framesPerSecond: 60))
        defer { source.stop() }

        var seen = 0
        for await frame in source.frames {
            XCTAssertEqual(frame.width, 4)
            XCTAssertEqual(frame.height, 2)
            XCTAssertEqual(frame.stride, 16)             // width * 4 bytes BGRA
            XCTAssertEqual(frame.data.count, 32)          // stride * height
            seen += 1
            if seen == 3 { break }
        }
        XCTAssertEqual(seen, 3)
    }

    func testFramesDifferBetweenTicksSoStalenessIsDetectable() async throws {
        let source = SyntheticCaptureSource()
        try source.start(configuration: CaptureConfiguration(width: 2, height: 1, framesPerSecond: 60))
        defer { source.stop() }

        var collected: [Data] = []
        for await frame in source.frames {
            collected.append(frame.data)
            if collected.count == 2 { break }
        }
        XCTAssertNotEqual(collected[0], collected[1])
    }

    func testStopEndsTheStream() async throws {
        let source = SyntheticCaptureSource()
        try source.start(configuration: CaptureConfiguration(width: 2, height: 1, framesPerSecond: 60))
        source.stop()

        var count = 0
        for await _ in source.frames { count += 1 }
        XCTAssertEqual(count, 0, "a stopped source must not keep emitting")
    }

    func testSyntheticSourceIsAvailableWhileLocked() {
        // It has no display dependency, so it is trivially lock-independent.
        XCTAssertTrue(SyntheticCaptureSource().isAvailableWhileLocked)
    }
}
