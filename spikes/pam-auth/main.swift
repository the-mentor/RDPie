// Probe: does OpenPAM's pam_authenticate() actually verify a local macOS
// account's password from an unprivileged, unsigned CLI process, or does it
// need special entitlements/authorization this process won't have?
// Build: swiftc -o pam-probe main.swift -import-objc-header pam-bridge.h -lpam
//
// Usage: ./pam-probe <username>
// Prompts for the password on stdin (not echoed) and reports whether PAM
// accepted it. Never logs or stores the password.
import Foundation

guard CommandLine.arguments.count > 1 else {
    print("usage: pam-probe <username>")
    exit(2)
}
let username = CommandLine.arguments[1]

print("Password for \(username): ", terminator: "")
// Disable terminal echo while reading the password.
var oldTerm = termios()
tcgetattr(STDIN_FILENO, &oldTerm)
var newTerm = oldTerm
newTerm.c_lflag &= ~UInt(ECHO)
tcsetattr(STDIN_FILENO, TCSANOW, &newTerm)
let password = readLine() ?? ""
tcsetattr(STDIN_FILENO, TCSANOW, &oldTerm)
print("")

let result = username.withCString { userC in
    password.withCString { passC in
        pamAuthenticate(userC, passC)
    }
}
print("pam_authenticate result: \(result) (0 = PAM_SUCCESS)")
