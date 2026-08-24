// Probe: does VTCompressionSession produce usable real-time H.264 for a
// screen-sharing use case, and in what NAL unit format?
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

let width = 640
let height = 480

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
    print("VTCompressionSessionCreate failed: \(status)")
    exit(1)
}

VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
VTCompressionSessionPrepareToEncodeFrames(session)

var pixelBuffer: CVPixelBuffer?
let pbStatus = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
guard pbStatus == kCVReturnSuccess, let pixelBuffer else {
    print("CVPixelBufferCreate failed: \(pbStatus)")
    exit(1)
}
CVPixelBufferLockBaseAddress(pixelBuffer, [])
if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    memset(base, 0x80, stride * height)
}
CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

let semaphore = DispatchSemaphore(value: 0)
var sawSampleBuffer: CMSampleBuffer?
var encodeError: OSStatus = noErr

VTCompressionSessionEncodeFrame(
    session,
    imageBuffer: pixelBuffer,
    presentationTimeStamp: CMTime(value: 0, timescale: 30),
    duration: CMTime(value: 1, timescale: 30),
    frameProperties: nil,
    infoFlagsOut: nil
) { status, flags, sbuf in
    encodeError = status
    sawSampleBuffer = sbuf
    semaphore.signal()
}

VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
_ = semaphore.wait(timeout: .now() + 5)

guard encodeError == noErr, let sbuf = sawSampleBuffer else {
    print("encode failed: \(encodeError)")
    exit(1)
}

print("encode succeeded")
print("isKeyFrame attachments: \(String(describing: CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false)))")

guard let blockBuffer = CMSampleBufferGetDataBuffer(sbuf) else {
    print("no data buffer")
    exit(1)
}
var length = 0
var dataPointer: UnsafeMutablePointer<Int8>?
CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
print("encoded byte count: \(length)")
if let dataPointer {
    let bytes = UnsafeRawBufferPointer(start: dataPointer, count: min(length, 16))
    print("first bytes (hex): \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
}

// Check the format description for avcC (length-prefixed) box, which tells us
// the NAL length-field size VideoToolbox is using — this output is AVCC, NOT
// Annex-B, and needs conversion before handing to MS-RDPEGFX.
if let formatDesc = CMSampleBufferGetFormatDescription(sbuf) {
    if let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] {
        print("format description extensions keys: \(extensions.keys.sorted())")
    }
    var parameterSetCount = 0
    let psStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
    print("parameter set count: \(parameterSetCount), status: \(psStatus)")
}
