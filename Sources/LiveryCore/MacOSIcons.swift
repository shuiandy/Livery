import AppKit
import Foundation

public struct IconHit: Codable {
    public var objectID: String?
    public var appName: String?
    public var appSlug: String?
    public var lowResPngUrl: String?
    public var icnsUrl: String?
    public var iOSUrl: String?
    public var category: String?
    public var credit: String?
    public var creditUrl: String?
    public var usersName: String?
    public var creator: String?
    public var uploadedBy: String?
    public var downloads: Int?
    public var timeStamp: Double?

    enum CodingKeys: String, CodingKey {
        case objectID, appName, appSlug, lowResPngUrl, icnsUrl, iOSUrl, category, categoryName
        case credit, creditUrl, usersName, creator, uploadedBy, downloads, timeStamp
    }

    /// macosicons sends numbers as numbers and `usersName`; Iconic sends `downloads`/`timeStamp` as strings and `creator`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectID = try c.decodeIfPresent(String.self, forKey: .objectID)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        appSlug = try c.decodeIfPresent(String.self, forKey: .appSlug)
        lowResPngUrl = try c.decodeIfPresent(String.self, forKey: .lowResPngUrl)
        icnsUrl = try c.decodeIfPresent(String.self, forKey: .icnsUrl)
        iOSUrl = try c.decodeIfPresent(String.self, forKey: .iOSUrl)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? c.decodeIfPresent(String.self, forKey: .categoryName)
        credit = try c.decodeIfPresent(String.self, forKey: .credit)
        creditUrl = try c.decodeIfPresent(String.self, forKey: .creditUrl)
        usersName = try c.decodeIfPresent(String.self, forKey: .usersName)
        creator = try c.decodeIfPresent(String.self, forKey: .creator)
        uploadedBy = try c.decodeIfPresent(String.self, forKey: .uploadedBy)
        downloads = IconHit.flexibleInt(c, .downloads)
        timeStamp = IconHit.flexibleDouble(c, .timeStamp)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(objectID, forKey: .objectID)
        try c.encodeIfPresent(appName, forKey: .appName)
        try c.encodeIfPresent(appSlug, forKey: .appSlug)
        try c.encodeIfPresent(lowResPngUrl, forKey: .lowResPngUrl)
        try c.encodeIfPresent(icnsUrl, forKey: .icnsUrl)
        try c.encodeIfPresent(iOSUrl, forKey: .iOSUrl)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(credit, forKey: .credit)
        try c.encodeIfPresent(creditUrl, forKey: .creditUrl)
        try c.encodeIfPresent(usersName, forKey: .usersName)
        try c.encodeIfPresent(creator, forKey: .creator)
        try c.encodeIfPresent(uploadedBy, forKey: .uploadedBy)
        try c.encodeIfPresent(downloads, forKey: .downloads)
        try c.encodeIfPresent(timeStamp, forKey: .timeStamp)
    }

    private static func flexibleInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let number = try? c.decodeIfPresent(Int.self, forKey: key) { return number }
        if let text = try? c.decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }

    private static func flexibleDouble(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let number = try? c.decodeIfPresent(Double.self, forKey: key) { return number }
        if let text = try? c.decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }

    /// Whoever made the icon: macosicons fills `usersName`, Iconic fills `creator`; `credit` is usually a link.
    public var author: String {
        if let usersName, !usersName.isEmpty { return usersName }
        if let creator, !creator.isEmpty { return creator }
        if let credit, !credit.isEmpty, !credit.hasPrefix("http") { return credit }
        return ""
    }

    /// Both catalogs share macosicons' object IDs, so the macosicons page is the canonical home of every hit.
    public var iconPageURL: String? {
        guard let objectID else { return nil }
        let slug = appSlug ?? appName.map(IconHit.slugify) ?? "icon"
        return "https://macosicons.com/icon/\(slug)-\(objectID)"
    }

    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var pendingDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "icon" : out
    }
}

extension IconHit: Identifiable {
    /// The catalog's own id; the artwork URL when a source omits it. Views key on this rather than on position.
    public var id: String { objectID ?? icnsUrl ?? lowResPngUrl ?? appName ?? "hit" }
}

public struct SearchResponse: Codable {
    public var hits: [IconHit]
    public var query: String?
    public var totalHits: Int?
    public var hitsPerPage: Int?
    public var page: Int?
    public var totalPages: Int?
}

public struct SearchCache: Codable {
    public var query: String
    public var page: Int
    public var firstIndex: Int
    public var hits: [IconHit]

    public init(query: String, page: Int, firstIndex: Int, hits: [IconHit]) {
        self.query = query
        self.page = page
        self.firstIndex = firstIndex
        self.hits = hits
    }

    public static func load() throws -> SearchCache {
        guard let data = try? Data(contentsOf: Paths.lastSearch) else {
            throw LiveryError("no cached search. Run: livery search <query> first")
        }
        return try JSONDecoder().decode(SearchCache.self, from: data)
    }

    public func save() throws {
        try Paths.ensureDirectories()
        try JSONEncoder().encode(self).write(to: Paths.lastSearch, options: .atomic)
    }

    public func hit(number: Int) throws -> IconHit {
        let offset = number - firstIndex
        guard offset >= 0, offset < hits.count else {
            throw LiveryError("#\(number) is not in the last search (\(firstIndex)...\(firstIndex + hits.count - 1))")
        }
        return hits[offset]
    }
}

/// Where searches go. Both serve the same 30,000-icon library with the same object IDs.
public enum IconSource: String, CaseIterable {
    /// icons.ahmetdedeler.com: public read API, no key, 1024 px PNG downloads.
    case iconic
    /// api.macosicons.com: needs a key; the free plan allows 50 calls a month, macOSicons+ 1,000.
    case macosicons

    public var title: String {
        switch self {
        case .iconic: return "Iconic catalog (no key)"
        case .macosicons: return "macosicons.com (API key)"
        }
    }

    public var needsKey: Bool { self == .macosicons }
}

/// HTTP 429. macosicons meters by month with no Retry-After header; Iconic has shown no limit so far.
public struct RateLimited: Error, CustomStringConvertible {
    public let source: IconSource
    public let retryAfter: TimeInterval?
    public init(source: IconSource, retryAfter: TimeInterval?) {
        self.source = source
        self.retryAfter = retryAfter
    }
    public var description: String {
        switch source {
        case .macosicons:
            return "macosicons.com API call limit exceeded: the free key allows 50 calls a month (macOSicons+ raises it to 1,000). Switch the icon source to the Iconic catalog, or wait for the monthly reset."
        case .iconic:
            return "The Iconic catalog is rate limiting right now" + (retryAfter.map { "; retry in \(Int($0)) s" } ?? "; try again in a few minutes.")
        }
    }
}

public enum IconCatalog {
    public static func search(_ query: String, page: Int, source: IconSource, raw: Bool = false) throws -> SearchResponse {
        var response: SearchResponse
        switch source {
        case .iconic: response = try Iconic.search(query, page: page, raw: raw)
        case .macosicons: response = try MacOSIcons.search(query, page: page, raw: raw)
        }
        var seen = Set<String>()
        response.hits = response.hits.filter { seen.insert($0.id).inserted }
        return response
    }
}

public enum Iconic {
    public static let endpoint = URL(string: "https://icons.ahmetdedeler.com/api/search")!

    /// Same request shape as macosicons; `hitsPerPage` is honoured here (verified 2026-09-02).
    public static func search(_ query: String, page: Int, raw: Bool) throws -> SearchResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "searchOptions": ["hitsPerPage": 50, "page": page]])
        let (data, response) = try HTTP.perform(request)
        if raw {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write("\n".data(using: .utf8)!)
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 429 {
                throw RateLimited(source: .iconic, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
            }
            throw LiveryError("Iconic API HTTP \(response.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try JSONDecoder().decode(SearchResponse.self, from: data)
    }
}

public enum MacOSIcons {
    public static let endpoint = URL(string: "https://api.macosicons.com/api/v1/search")!

    public static func apiKey() throws -> String {
        if let env = ProcessInfo.processInfo.environment["MACOSICONS_API_KEY"], !env.isEmpty { return env }
        if let stored = try? String(contentsOf: Paths.apiKeyFile, encoding: .utf8) {
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                tightenPermissions(of: Paths.apiKeyFile)
                return trimmed
            }
        }
        throw LiveryError("no API key. Get a free one at https://macosicons.com/developers, then run: livery key <KEY> (stored in \(Paths.apiKeyFile.path))")
    }

    /// A key file left group- or world-readable is readable by every other account on the Mac. Fix it in place rather
    /// than refusing to work, and say so once.
    private static func tightenPermissions(of file: URL) {
        guard let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) as? NSNumber,
              mode.uint16Value & 0o077 != 0 else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        Log.error("\(file.path) was readable by other accounts; tightened it to 0600")
    }

    public static func saveKey(_ key: String) throws {
        try Paths.ensureDirectories()
        try key.write(to: Paths.apiKeyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.apiKeyFile.path)
    }

    /// Page size is fixed at 50 server side; only `searchOptions.page` is honoured (verified 2026-09-02).
    public static func search(_ query: String, page: Int, raw: Bool) throws -> SearchResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try apiKey(), forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "searchOptions": ["page": page]])
        let (data, response) = try HTTP.perform(request)
        if raw {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write("\n".data(using: .utf8)!)
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 429 {
                throw RateLimited(source: .macosicons, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
            }
            throw LiveryError("macosicons API HTTP \(response.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try JSONDecoder().decode(SearchResponse.self, from: data)
    }

    /// Icons are a few megabytes at most; anything larger is a catalog entry gone wrong or a deliberate flood.
    public static let maxIconBytes = 16 * 1024 * 1024

    public static func download(_ urlString: String) throws -> Data {
        guard let url = URL(string: urlString) else { throw LiveryError("bad url \(urlString)") }
        let (data, response) = try HTTP.perform(URLRequest(url: url), maxBytes: maxIconBytes)
        guard response.statusCode == 200 else { throw LiveryError("download \(urlString) returned HTTP \(response.statusCode)") }
        return data
    }
}

/// Everything downloaded here comes from a catalog Livery does not control, and the URLs inside a reply are
/// chosen by whoever uploaded the icon. So the transport is pinned to HTTPS, redirects are re-checked rather than
/// followed blindly, addresses on this machine or the local network are refused, and both the time and the size of a
/// reply are bounded.
public enum HTTP {
    public static let maxResponseBytes = 32 * 1024 * 1024

    /// Rejects anything that is not plain HTTPS to a routable host. The name is checked, and so is every address it
    /// resolves to right now: a public name pointed at 127.0.0.1 or 10.x is refused the same as the literal would be.
    public static func validate(_ url: URL?) throws {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else {
            throw LiveryError("refusing a URL that is not HTTPS: \(url?.absoluteString ?? "none")")
        }
        guard !isLocal(host) else { throw LiveryError("refusing a URL that points at a private address: \(host)") }
        if let address = resolve(host).first(where: isLocal) {
            throw LiveryError("refusing \(host): it resolves to the private address \(address)")
        }
    }

    static func isLocal(_ host: String) -> Bool {
        var host = host.lowercased()
        if let scope = host.firstIndex(of: "%") { host = String(host[..<scope]) }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return true }
        if host.hasPrefix("::ffff:") { host = String(host.dropFirst(7)) }
        if host == "::1" || host == "::" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (0, _), (169, 254): return true
        case (192, 168): return true
        case (172, let second) where (16...31).contains(second): return true
        default: return false
        }
    }

    /// The textual addresses `host` resolves to right now. Empty when resolution fails, in which case the request
    /// itself fails a moment later. A record that changes between this lookup and the connection is outside what a
    /// client can see; the catalog hosts are fixed and reputable, and this closes the plain case.
    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }

    public static func perform(_ request: URLRequest, maxBytes: Int = maxResponseBytes) throws -> (Data, HTTPURLResponse) {
        try validate(request.url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let guardian = TransferGuard(maxBytes: maxBytes)
        let session = URLSession(configuration: configuration, delegate: guardian, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        session.dataTask(with: request).resume()
        return try guardian.wait()
    }

    /// One transfer's delegate. A redirect is a fresh destination chosen by the server, so it goes through the same
    /// check as the first URL, and the body is cut off the moment it passes the cap rather than being read to the end
    /// and measured afterwards.
    private final class TransferGuard: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maxBytes: Int
        private let semaphore = DispatchSemaphore(value: 0)
        private var buffer = Data()
        private var response: HTTPURLResponse?
        private var failure: Error?

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        func wait() throws -> (Data, HTTPURLResponse) {
            semaphore.wait()
            if let failure { throw failure }
            guard let response else { throw LiveryError("no HTTP response") }
            return (buffer, response)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            do {
                try HTTP.validate(request.url)
                completionHandler(request)
            } catch {
                failure = error
                completionHandler(nil)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                failure = LiveryError("no HTTP response")
                completionHandler(.cancel)
                return
            }
            if http.expectedContentLength > Int64(maxBytes) {
                failure = LiveryError("the reply announces \(http.expectedContentLength) bytes, over the \(maxBytes) byte limit")
                completionHandler(.cancel)
                return
            }
            self.response = http
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            buffer.append(data)
            if buffer.count > maxBytes {
                failure = LiveryError("the reply passed the \(maxBytes) byte limit")
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if failure == nil, let error { failure = error }
            semaphore.signal()
        }
    }
}

/// Numbered grid of the search hits so a pick can be made by eye instead of by URL.
public enum ContactSheet {
    public static func render(hits: [IconHit], firstIndex: Int, to url: URL) throws {
        let cell = 176
        let columns = 6
        let padding = 12
        let labelHeight = 44
        let rows = max(1, Int((Double(hits.count) / Double(columns)).rounded(.up)))
        let width = columns * cell
        let height = rows * (cell + labelHeight)

        // Each download blocks on a semaphore until URLSession answers, and URLSession answers on the GCD pool.
        // Blocking that same pool with a few dozen waiters could starve it, so the waiting happens on threads of
        // their own, a handful at a time, and the calling thread waits for all of them.
        var images = [NSImage?](repeating: nil, count: hits.count)
        let lock = NSLock()
        var next = 0
        let finished = DispatchSemaphore(value: 0)
        let workers = min(6, max(1, hits.count))
        for _ in 0..<workers {
            Thread {
                while true {
                    lock.lock()
                    let index = next
                    next += 1
                    lock.unlock()
                    guard index < hits.count else { break }
                    guard let urlString = hits[index].lowResPngUrl, let data = try? MacOSIcons.download(urlString) else { continue }
                    let image = NSImage(data: data)
                    lock.lock()
                    images[index] = image
                    lock.unlock()
                }
                finished.signal()
            }.start()
        }
        for _ in 0..<workers { finished.wait() }

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw LiveryError("bitmap allocation failed")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white,
        ]
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.8, alpha: 1),
        ]
        for (index, hit) in hits.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = column * cell
            let originY = height - (row + 1) * (cell + labelHeight)
            if let image = images[index] {
                let frame = NSRect(x: x + padding, y: originY + labelHeight + padding,
                                   width: cell - 2 * padding, height: cell - 2 * padding)
                image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            }
            ("#\(firstIndex + index)" as NSString).draw(at: NSPoint(x: x + padding, y: originY + labelHeight - 24),
                                                        withAttributes: numberAttributes)
            let caption = "\(hit.appName ?? "?")  \(hit.author)  \(hit.downloads ?? 0) dl"
            let captionRect = NSRect(x: x + padding, y: originY + 2, width: cell - 2 * padding, height: 18)
            (caption as NSString).draw(with: captionRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                       attributes: captionAttributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw LiveryError("png encode failed") }
        try png.write(to: url)
    }
}
