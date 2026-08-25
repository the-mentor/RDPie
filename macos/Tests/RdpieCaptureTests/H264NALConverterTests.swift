// macos/Tests/RdpieCaptureTests/H264NALConverterTests.swift
import XCTest
@testable import RdpieCapture

final class H264NALConverterTests: XCTestCase {

    private func avccLengthPrefixed(_ nals: [[UInt8]]) -> Data {
        var data = Data()
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: nal)
        }
        return data
    }

    func testSingleNALUnit() {
        let nal: [UInt8] = [0x06, 0x01, 0x02, 0x03]
        let avcc = avccLengthPrefixed([nal])

        let annexB = H264NALConverter.avccToAnnexB(avcc)

        let expected: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x02, 0x03]
        XCTAssertEqual(Array(annexB), expected)
    }

    func testMultipleNALUnitsInOneBuffer() {
        let first: [UInt8] = [0x06, 0xaa]
        let second: [UInt8] = [0x65, 0xbb, 0xcc]
        let avcc = avccLengthPrefixed([first, second])

        let annexB = H264NALConverter.avccToAnnexB(avcc)

        let expected: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, 0x06, 0xaa,
            0x00, 0x00, 0x00, 0x01, 0x65, 0xbb, 0xcc,
        ]
        XCTAssertEqual(Array(annexB), expected)
    }

    func testKeyframePrependsSPSAndPPS() {
        let sps = Data([0x67, 0x42, 0x00, 0x1e])
        let pps = Data([0x68, 0xce, 0x3c, 0x80])
        let frame: [UInt8] = [0x65, 0x01, 0x02]
        let frameAVCC = avccLengthPrefixed([frame])

        let annexB = H264NALConverter.annexBKeyframe(sps: sps, pps: pps, frameAVCC: frameAVCC)

        var expected = Data()
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        expected.append(sps)
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        expected.append(pps)
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        expected.append(contentsOf: frame)

        XCTAssertEqual(annexB, expected)
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertEqual(H264NALConverter.avccToAnnexB(Data()), Data())
    }
}
