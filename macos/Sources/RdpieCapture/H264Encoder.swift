// macos/Sources/RdpieCapture/H264Encoder.swift
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// One H.264-encoded access unit, already converted to Annex-B and ready
/// for `RustBridge.submitH264`.
public struct EncodedH264Frame: Sendable {
    public let data: Data
    public let isKeyframe: Bool
    public let timestampMs: UInt32
}

public enum H264EncoderError: Error {
    case sessionCreationFailed(OSStatus)
    case pixelBufferCreationFailed
    case encodeFailed(OSStatus)
    case missingSampleData
}

/// Wraps a `VTCompressionSession` configured per
/// `spikes/videotoolbox-h264/RESULTS.md`: H.264 Baseline, real-time, no
/// B-frames — MS-RDPEGFX and low-latency screen sharing both need
/// frame-at-a-time output, not a reordered GOP.
public final class H264Encoder {
    private var session: VTCompressionSession?

    public init(width: Int, height: Int, maxKeyframeIntervalFrames: Int32 = 120) throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw H264EncoderError.sessionCreationFailed(status)
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: maxKeyframeIntervalFrames as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)

        self.session = session
    }

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    /// Encodes one BGRA `CapturedFrame`. `timestampMs` is caller-supplied
    /// (main.swift derives it from a monotonic clock) since it doubles as
    /// both the VT presentation timestamp and the value handed to
    /// `rdpie_server_submit_h264_frame`. Returns `nil`, not an error, if
    /// VideoToolbox produced no sample for this call — a dropped frame here
    /// is recoverable, the next capture tick supplies a new one.
    public func encode(_ frame: CapturedFrame, timestampMs: UInt32) async throws -> EncodedH264Frame? {
        guard let session else { throw H264EncoderError.sessionCreationFailed(kVTInvalidSessionErr) }
        guard let pixelBuffer = makePixelBuffer(from: frame) else {
            throw H264EncoderError.pixelBufferCreationFailed
        }

        let pts = CMTime(value: Int64(timestampMs), timescale: 1000)

        return try await withCheckedThrowingContinuation { continuation in
            let enqueueStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { encodeStatus, _, sampleBuffer in
                if encodeStatus != noErr {
                    continuation.resume(throwing: H264EncoderError.encodeFailed(encodeStatus))
                    return
                }
                guard let sampleBuffer else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let encoded = try Self.makeEncodedFrame(from: sampleBuffer, timestampMs: timestampMs)
                    continuation.resume(returning: encoded)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            // The completion handler above is not invoked when the enqueue
            // itself fails (documented VTCompressionSessionEncodeFrame
            // behavior), so this is the only path that resumes on failure —
            // no double-resume risk between this and the handler.
            if enqueueStatus != noErr {
                continuation.resume(throwing: H264EncoderError.encodeFailed(enqueueStatus))
            }
        }
    }

    private static func makeEncodedFrame(from sampleBuffer: CMSampleBuffer, timestampMs: UInt32) throws -> EncodedH264Frame {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw H264EncoderError.missingSampleData
        }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let blockStatus = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard blockStatus == noErr, let dataPointer else {
            throw H264EncoderError.missingSampleData
        }
        let avcc = Data(bytes: dataPointer, count: length)

        // Per spike RESULTS.md: `DependsOnOthers == false` marks a keyframe
        // (IDR). No attachments array at all also means a sync sample under
        // the general CMSampleBuffer convention, so absence defaults to
        // "keyframe" rather than "not a keyframe".
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let dependsOnOthers = (attachments?.first?[kCMSampleAttachmentKey_DependsOnOthers] as? Bool) ?? false
        let isKeyframe = !dependsOnOthers

        let annexB: Data
        if isKeyframe {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                throw H264EncoderError.missingSampleData
            }
            let sps = try parameterSet(formatDescription, index: 0)
            let pps = try parameterSet(formatDescription, index: 1)
            annexB = H264NALConverter.annexBKeyframe(sps: sps, pps: pps, frameAVCC: avcc)
        } else {
            annexB = H264NALConverter.avccToAnnexB(avcc)
        }

        return EncodedH264Frame(data: annexB, isKeyframe: isKeyframe, timestampMs: timestampMs)
    }

    private static func parameterSet(_ formatDescription: CMFormatDescription, index: Int) throws -> Data {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: index,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil)
        guard status == noErr, let pointer else {
            throw H264EncoderError.missingSampleData
        }
        return Data(bytes: pointer, count: size)
    }

    /// Copies `CapturedFrame`'s BGRA `Data` into a fresh `CVPixelBuffer`.
    /// Handles a stride mismatch between the source and the buffer
    /// VideoToolbox allocates (IOSurface row alignment can differ from
    /// ScreenCaptureKit's) by copying row-by-row instead of assuming a flat
    /// memcpy is safe.
    private func makePixelBuffer(from frame: CapturedFrame) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(
            nil, frame.width, frame.height, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let destStride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        frame.data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let src = buffer.baseAddress else { return }
            if destStride == frame.stride {
                memcpy(base, src, frame.stride * frame.height)
            } else {
                let copyWidth = min(destStride, frame.stride)
                for row in 0..<frame.height {
                    memcpy(base + row * destStride, src + row * frame.stride, copyWidth)
                }
            }
        }
        return pixelBuffer
    }
}
