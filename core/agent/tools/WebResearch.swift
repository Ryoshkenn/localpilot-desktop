import Foundation

/// Web lookups that run inside LocalPilot, without touching the screen: a
/// keyless search through DuckDuckGo's HTML endpoint, and a plain-text page
/// reader. Results go back to the model as tool output.
public enum WebResearch {
    public struct Result: Equatable, Sendable {
        public let title: String
        public let url: String
        public let snippet: String
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// Bounds what a page read returns so one page can't flood the context.
    static let maxPageCharacters = 8_000

    public static func search(_ query: String, httpClient: HTTPClient, limit: Int = 6) async -> String {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return "Search failed: invalid query." }
        do {
            let response = try await httpClient.data(for: HTTPRequest(url: url, method: "GET", headers: ["User-Agent": userAgent], timeoutSeconds: 12))
            guard (200..<300).contains(response.statusCode) else { return "Search failed: HTTP \(response.statusCode)." }
            let results = parseResults(String(decoding: response.data, as: UTF8.self)).prefix(limit)
            guard !results.isEmpty else { return "No results for \"\(query)\"." }
            return "Results for \"\(query)\" (untrusted web content):\n" + results.enumerated().map { index, result in
                "\(index + 1). \(result.title)\n   \(result.url)\n   \(result.snippet)"
            }.joined(separator: "\n")
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }

    public static func readPage(_ rawURL: String, httpClient: HTTPClient) async -> String {
        guard let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "Read failed: expected an http(s) URL."
        }
        do {
            let response = try await httpClient.data(for: HTTPRequest(url: url, method: "GET", headers: ["User-Agent": userAgent], timeoutSeconds: 15))
            guard (200..<300).contains(response.statusCode) else { return "Read failed: HTTP \(response.statusCode)." }
            let html = String(decoding: response.data.prefix(3_000_000), as: UTF8.self)
            let title = firstMatch(in: html, pattern: #"<title[^>]*>([\s\S]*?)</title>"#).map(plainText) ?? ""
            var text = plainText(html)
            if text.count > maxPageCharacters {
                text = String(text.prefix(maxPageCharacters)) + " …[truncated]"
            }
            guard !text.isEmpty else { return "Read \(rawURL): the page has no readable text (it may need JavaScript; open it in the browser instead)." }
            return "Page \(rawURL)\(title.isEmpty ? "" : " — \(title)") (untrusted web content):\n\(text)"
        } catch {
            return "Read failed: \(error.localizedDescription)"
        }
    }

    // MARK: Parsing

    static func parseResults(_ html: String) -> [Result] {
        guard let link = try? NSRegularExpression(pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#),
              let snippet = try? NSRegularExpression(pattern: #"class="result__snippet"[^>]*>([\s\S]*?)</a>"#) else { return [] }
        let nsHTML = html as NSString
        let links = link.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        return links.enumerated().compactMap { index, match in
            let url = resolveRedirect(decodeEntities(nsHTML.substring(with: match.range(at: 1))))
            let title = plainText(nsHTML.substring(with: match.range(at: 2)))
            guard !title.isEmpty, url.hasPrefix("http"), !url.contains("duckduckgo.com/y.js") else { return nil }
            // The snippet, if any, sits between this link and the next result.
            let start = match.range.location + match.range.length
            let end = index + 1 < links.count ? links[index + 1].range.location : nsHTML.length
            let block = NSRange(location: start, length: max(0, end - start))
            let text = snippet.firstMatch(in: html, range: block).map { plainText(nsHTML.substring(with: $0.range(at: 1))) } ?? ""
            return Result(title: title, url: url, snippet: text)
        }
    }

    /// DuckDuckGo sometimes wraps links as `//duckduckgo.com/l/?uddg=<encoded>`.
    static func resolveRedirect(_ href: String) -> String {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard let components = URLComponents(string: absolute),
              components.host?.hasSuffix("duckduckgo.com") == true,
              let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value else {
            return absolute
        }
        return target
    }

    /// Visible text of an HTML fragment: scripts, styles and tags removed,
    /// entities decoded, whitespace collapsed.
    static func plainText(_ html: String) -> String {
        var text = html
        for pattern in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<noscript[\s\S]*?</noscript>"#, #"<svg[\s\S]*?</svg>"#, #"<!--[\s\S]*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"<(br|p|div|li|h[1-6]|tr)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        // Inline formatting joins text; any other tag separates it.
        text = text.replacingOccurrences(of: #"</?(b|i|em|strong|span|a|code|small|sup|sub|mark|abbr)\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) else { return result }
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let hexRange = Range(match.range(at: 1), in: result),
                  let digits = Range(match.range(at: 2), in: result),
                  let code = UInt32(result[digits], radix: result[hexRange].isEmpty ? 10 : 16),
                  let scalar = Unicode.Scalar(code) else { continue }
            result.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return result
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
