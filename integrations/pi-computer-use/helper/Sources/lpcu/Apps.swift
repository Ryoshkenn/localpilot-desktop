import AppKit

/// Launching and finding applications by the loose names a model uses
/// ("chrome", "System Settings", "vscode").
@MainActor
enum Apps {
    private static let aliases: [String: String] = [
        "chrome": "Google Chrome", "google": "Google Chrome", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
        "settings": "System Settings", "system preferences": "System Settings", "preferences": "System Settings",
        "terminal": "Terminal", "browser": "Safari", "web browser": "Safari", "notes": "Notes", "mail": "Mail",
        "calculator": "Calculator", "calc": "Calculator", "textedit": "TextEdit", "text edit": "TextEdit",
        "finder": "Finder", "files": "Finder", "word": "Microsoft Word", "messages": "Messages",
    ]

    private static var searchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            home.appendingPathComponent("Applications"),
        ]
    }

    static func installed() -> [URL] {
        var result: [URL] = []
        for directory in searchDirectories {
            guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            result.append(contentsOf: items.filter { $0.pathExtension == "app" })
        }
        return result
    }

    static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: ".app", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    /// Best installed app for a loose name: exact, then alias, then prefix,
    /// then substring match.
    static func find(named rawName: String) -> URL? {
        let name = normalize(rawName)
        let wanted = aliases[name].map(normalize) ?? name
        let apps = installed()
        let named = apps.map { ($0, normalize($0.deletingPathExtension().lastPathComponent)) }
        if let exact = named.first(where: { $0.1 == wanted }) { return exact.0 }
        if let prefix = named.filter({ $0.1.hasPrefix(wanted) }).min(by: { $0.1.count < $1.1.count }) { return prefix.0 }
        if let contains = named.filter({ $0.1.contains(wanted) }).min(by: { $0.1.count < $1.1.count }) { return contains.0 }
        if let reverse = named.first(where: { wanted.contains($0.1) && $0.1.count >= 4 }) { return reverse.0 }
        return nil
    }

    static func running(named rawName: String) -> NSRunningApplication? {
        let name = normalize(rawName)
        let wanted = aliases[name].map(normalize) ?? name
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { normalize($0.localizedName ?? "") == wanted }
            ?? apps.first { normalize($0.localizedName ?? "").hasPrefix(wanted) }
            ?? apps.first { normalize($0.localizedName ?? "").contains(wanted) }
    }

    static func runningList() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
    }

    static func open(name: String) async throws -> NSRunningApplication {
        guard let url = find(named: name) else {
            let suggestions = installed().map { $0.deletingPathExtension().lastPathComponent }
                .filter { normalize($0).contains(normalize(name).prefix(3)) }
                .prefix(5)
            throw HelperError("no app named \"\(name)\"" + (suggestions.isEmpty ? "" : "; did you mean: " + suggestions.joined(separator: ", ")))
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        // Launch returns before the app finishes starting; wait for it to be frontmost.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !app.isFinishedLaunching || NSWorkspace.shared.frontmostApplication != app {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return app
    }

    static func open(url rawURL: String, appName: String?, currentTarget: NSRunningApplication?) async throws -> NSRunningApplication? {
        var text = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else {
            throw HelperError("not a web URL: \(rawURL)")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Open in the named browser, else the target app if it is a browser,
        // else the default browser.
        var browser: URL?
        if let appName { browser = find(named: appName) }
        if browser == nil, let currentTarget, let bundle = currentTarget.bundleURL, isBrowser(currentTarget) { browser = bundle }
        if let browser {
            return try await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: configuration)
        }
        NSWorkspace.shared.open(url)
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL == handler }
    }

    static func isBrowser(_ app: NSRunningApplication) -> Bool {
        let ids: Set<String> = [
            "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
            "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
        ]
        return app.bundleIdentifier.map(ids.contains) ?? false
    }
}
