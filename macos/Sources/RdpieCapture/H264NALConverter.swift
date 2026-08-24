// macos/Sources/RdpieCapture/H264NALConverter.swift
import Foundation

/// Converts VideoToolbox's AVCC-format H.264 output (4-byte big-endian
/// length-prefixed NAL units, no inline SPS/PPS) to Annex-B (start-code
/// prefixed NAL units), which is what MS-RDPEGFX's AVC420 codec expects.
/// Pure byte manipulation, no VideoToolbox dependency — see
/// `spikes/videotoolbox-h264/RESULTS.md` for the format this was derived
/// from.
public enum H264NALConverter {
    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    /// Rewrites one AVCC buffer (as produced by `CMBlockBufferGetDataPointer`
    /// on a VideoToolbox-encoded sample) as Annex-B, preserving NAL order.
    /// A length prefix that would overrun the buffer is treated as
    /// end-of-data rather than trapping — a corrupt/truncated frame should
    /// be dropped by the caller, not crash the encode loop.
    public static func avccToAnnexB(_ avcc: Data) -> Data {
        var output = Data()
        var offset = avcc.startIndex
        let end = avcc.endIndex

        while offset < end {
            guard end - offset >= 4 else { break }
            let length = Int(readUInt32BE(avcc, at: offset))
            offset += 4
            guard length > 0, end - offset >= length else { break }

            output.append(contentsOf: startCode)
            output.append(avcc[offset..<offset + length])
            offset += length
        }

        return output
    }

    /// Builds a full Annex-B keyframe: SPS, then PPS, then the frame's own
    /// NAL units. VideoToolbox never inlines SPS/PPS in the bitstream, so
    /// the caller (`H264Encoder`) fetches them separately and this function
    /// stitches everything into the single buffer MS-RDPEGFX expects.
    public static func annexBKeyframe(sps: Data, pps: Data, frameAVCC: Data) -> Data {
        var output = Data()
        output.append(contentsOf: startCode)
        output.append(sps)
        output.append(contentsOf: startCode)
        output.append(pps)
        output.append(avccToAnnexB(frameAVCC))
        return output
    }

    private static func readUInt32BE(_ data: Data, at offset: Data.Index) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }
}
