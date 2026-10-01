import AppKit
import Foundation

// lpcu — LocalPilot computer-use helper.
//
// Reads one JSON request per line on stdin ({"id":1,"cmd":"observe","args":{}})
// and writes one JSON response per line on stdout ({"id":1,"ok":true,"result":{}}).
// Requests run one at a time, in order. Element ids from the last `observe`
// stay valid until the next `observe`, so the caller can say "click 12".
//
// For debugging, a single command can be run directly:
//   lpcu observe
//   lpcu click '{"id":3}'

setvbuf(stdout, nil, _IOLBF, 0)

let application = NSApplication.shared
// Accessory (no Dock icon) rather than prohibited, so the helper may show the
// on-screen agent indicator window.
application.setActivationPolicy(.accessory)

let server = MainActor.assumeIsolated { Server() }
let arguments = Array(CommandLine.arguments.dropFirst())

if let command = arguments.first, command != "serve" {
    Task { @MainActor in
        var args: [String: Any] = [:]
        if arguments.count > 1, let data = arguments[1].data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        }
        let response = await server.run(command: command, args: args, requestID: 0)
        print(Server.encode(response, pretty: true))
        exit(0)
    }
} else {
    let (lines, continuation) = AsyncStream<String>.makeStream()
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) {
            continuation.yield(line)
        }
        continuation.finish()
    }
    Task { @MainActor in
        for await line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let response = await server.handle(line: trimmed)
            print(Server.encode(response, pretty: false))
        }
        exit(0)
    }
}

application.run()
