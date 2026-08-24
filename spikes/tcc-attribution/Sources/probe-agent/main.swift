// spikes/tcc-attribution/Sources/probe-agent/main.swift
import Foundation
import CoreGraphics
import ApplicationServices
import ServiceManagement

// This binary plays two roles, selected by argv[1], so one signed executable
// covers both "register me as a LaunchAgent" and "I am the LaunchAgent,
// probe my own TCC status" without a second target to build and sign.
let plistName = "com.rdpie.tccprobe.plist"

func service() -> SMAppService {
    SMAppService.agent(plistName: plistName)
}

let args = CommandLine.arguments
if args.count > 1 {
    switch args[1] {
    case "--register":
        do {
            try service().register()
            print("register() succeeded; status: \(service().status)")
        } catch {
            print("register() failed: \(error)")
        }
        exit(0)
    case "--unregister":
        do {
            try service().unregister()
            print("unregister() succeeded")
        } catch {
            print("unregister() failed: \(error)")
        }
        exit(0)
    case "--status":
        print("status: \(service().status)")
        exit(0)
    default:
        FileHandle.standardError.write("unknown argument: \(args[1])\n".data(using: .utf8)!)
        exit(1)
    }
}

// No arguments: this is the agent path, the one launchd actually runs.
let log = FileHandle(forWritingAtPath: "/tmp/rdpie-tcc-probe.log")
    ?? { FileManager.default.createFile(atPath: "/tmp/rdpie-tcc-probe.log", contents: nil)
         return FileHandle(forWritingAtPath: "/tmp/rdpie-tcc-probe.log")! }()

func note(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    log.write(line.data(using: .utf8)!)
}

note("bundle id: \(Bundle.main.bundleIdentifier ?? "<none>")")
note("executable: \(Bundle.main.executablePath ?? "<none>")")
note("screen recording preflight: \(CGPreflightScreenCaptureAccess())")
note("accessibility trusted: \(AXIsProcessTrusted())")

// Requesting from a background agent is the behaviour under test:
// does a system prompt appear at all, and against which identity?
note("requesting screen capture access…")
let granted = CGRequestScreenCaptureAccess()
note("request returned: \(granted)")
note("screen recording preflight after request: \(CGPreflightScreenCaptureAccess())")
