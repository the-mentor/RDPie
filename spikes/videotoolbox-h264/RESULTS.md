# Spike: VideoToolbox H.264 encoding — output format for MS-RDPEGFX

**Hardware:** Mac mini (Macmini9,1), Apple M1
**macOS:** 26.5.1 (build 25F80)
**Date:** 2026-08-24

## Procedure

Created a `VTCompressionSession` for H.264 Baseline profile, real-time mode,
`AllowFrameReordering = false` (required — B-frames are incompatible with
low-latency screen sharing and with MS-RDPEGFX's frame-at-a-time model).
Encoded one synthetic 640x480 BGRA frame and inspected the output
`CMSampleBuffer`.

## Result

- Encode succeeded. `DependsOnOthers = 0` on the sample attachment confirms
  it's a keyframe (IDR), as expected for the first frame.
- **Output is AVCC (4-byte big-endian length-prefixed NAL units), not
  Annex-B.** First bytes: `00 00 00 3b 06 05 32 47 ...` — `0x0000003b` (59)
  is a length prefix, `0x06` is a NAL unit type byte (SEI), not an Annex-B
  start code (`00 00 00 01` / `00 00 01`).
- SPS/PPS are **not** inline in the bitstream. They're retrievable
  separately via `CMVideoFormatDescriptionGetH264ParameterSetAtIndex`
  (`parameter set count: 2` — one SPS, one PPS) from the sample's format
  description.

## Implication for Phase 2

`ironrdp-egfx`'s `send_avc420_frame(surface_id, h264_data: &[u8], ...)`
takes a raw byte slice and does no NAL-format interpretation itself — the
caller is responsible for supplying whatever format MS-RDPEGFX expects
(Annex-B, per the H.264 elementary-stream convention used elsewhere in
RDP). This means the Swift encoder wrapper cannot just hand VideoToolbox's
`CMBlockBuffer` bytes to the FFI as-is; it must:

1. Walk the AVCC length-prefixed NAL units and rewrite each as
   `00 00 00 01`-prefixed Annex-B.
2. On keyframes, prepend the SPS and PPS (also as Annex-B NAL units, start
   code + raw parameter-set bytes) fetched via
   `CMVideoFormatDescriptionGetH264ParameterSetAtIndex` — VideoToolbox does
   not put these in the bitstream itself.

This is a concrete conversion step to design for explicitly, not an
implementation detail to discover mid-task.

## Caveats

- Single data point: one Mac, one macOS version, a flat synthetic frame.
  Not verified against a real ScreenCaptureKit-sourced frame or across
  multiple consecutive frames (P-frame NAL structure, periodic keyframe
  behavior at the configured `MaxKeyFrameInterval`).
- AVC444 (4:4:4 chroma) was not probed — VideoToolbox's native H.264
  encoder path here produces 4:2:0 output; AVC444's luma/chroma dual-stream
  format needs separate investigation before Phase 2 attempts it.
