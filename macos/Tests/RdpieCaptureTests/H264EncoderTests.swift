// macos/Tests/RdpieCaptureTests/H264EncoderTests.swift
import XCTest
@testable import RdpieCapture

final class H264EncoderTests: XCTestCase {

    private func makeSolidBGRAFrame(width: Int, height: Int, value: UInt8) -> CapturedFrame {
        let stride = width * 4
        return CapturedFrame(width: width, height: height, stride: stride,
                              data: Data(repeating: value, count: stride * height))
    }

    func testFirstEncodedFrameIsAKeyframeWithAnnexBStartCode() async throws {
        let encoder = try H264Encoder(width: 64, height: 64)
        let frame = makeSolidBGRAFrame(width: 64, height: 64, value: 0x40)

        let encoded = try await encoder.encode(frame, timestampMs: 0)

        let result = try XCTUnwrap(encoded)
        XCTAssertTrue(result.isKeyframe)
        XCTAssertFalse(result.data.isEmpty)
        XCTAssertEqual(Array(result.data.prefix(4)), [0x00, 0x00, 0x00, 0x01])
        XCTAssertEqual(result.timestampMs, 0)
    }

    func testSecondEncodedFrameIsNotAKeyframe() async throws {
        let encoder = try H264Encoder(width: 64, height: 64)
        let first = makeSolidBGRAFrame(width: 64, height: 64, value: 0x10)
        let second = makeSolidBGRAFrame(width: 64, height: 64, value: 0x20)

        _ = try await encoder.encode(first, timestampMs: 0)
        let secondEncoded = try await encoder.encode(second, timestampMs: 33)

        let result = try XCTUnwrap(secondEncoded)
        XCTAssertFalse(result.isKeyframe)
        XCTAssertFalse(result.data.isEmpty)
    }
}
