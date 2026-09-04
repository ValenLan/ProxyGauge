import Darwin
import Foundation

struct ExitSummarySnapshot: Equatable, Sendable {
    let address: String
    let location: String

    static let checking = ExitSummarySnapshot(
        address: "正在读取…",
        location: "正在确认实际网络出口"
    )

    static let disconnected = ExitSummarySnapshot(
        address: "已断开网络连接",
        location: "当前互联网连接不可用；局域网可能仍可用"
    )

    static let unavailable = ExitSummarySnapshot(
        address: "暂时无法读取",
        location: "请检查当前网络连接"
    )
}

private struct ParsedExitSummary: Sendable {
    let snapshot: ExitSummarySnapshot
    let hasCountry: Bool
}

protocol ExitSummaryResolving: Sendable {
    func resolve() async -> ExitSummarySnapshot
}

typealias ExitSummaryDataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

private final class ExitSummaryRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Resolves the address seen on the actual macOS network path. An ephemeral URLSession
/// intentionally keeps the system proxy/PAC/VPN behavior instead of forcing a Mihomo port.
/// The lookup service can see the resulting public IP and request time, but this request does
/// not include ProxyGauge's proxy endpoint, credentials, subscription, or configuration.
final class SystemExitSummaryService: ExitSummaryResolving, @unchecked Sendable {
    private static let summaryURL = URL(string: "https://ipapi.co/json/")!
    private static let secondarySummaryURL = URL(
        string: "https://ipwho.is/?fields=success,ip,country,country_code,region,city"
    )!
    private static let fallbackURLs = [
        URL(string: "https://api.ipify.org")!,
        URL(string: "https://ifconfig.me/ip")!,
        URL(string: "https://ip.sb/ip")!
    ]
    private static let maximumResponseBytes = 64 * 1024
    private static let defaultResolveTimeoutNanoseconds: UInt64 = 15_000_000_000

    private static let maximumLocationCharacters = 128
    private static let maximumCombinedLocationCharacters = 160
    private let injectedLoader: ExitSummaryDataLoader?
    private let resolveTimeoutNanoseconds: UInt64

    init() {
        injectedLoader = nil
        resolveTimeoutNanoseconds = Self.defaultResolveTimeoutNanoseconds
    }

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json, text/plain;q=0.9",
            "Cache-Control": "no-cache, no-store, max-age=0",
            "Pragma": "no-cache"
        ]
        return configuration
    }

    init(
        loader: @escaping ExitSummaryDataLoader,
        resolveTimeoutNanoseconds: UInt64 = SystemExitSummaryService.defaultResolveTimeoutNanoseconds
    ) {
        injectedLoader = loader
        self.resolveTimeoutNanoseconds = resolveTimeoutNanoseconds
    }

    func resolve() async -> ExitSummarySnapshot {
        guard !Task.isCancelled else { return .unavailable }
        if let injectedLoader {
            return await resolveWithinBudget(using: injectedLoader)
        }

        // Use a fresh session for every generation so a keep-alive connection from an old
        // proxy/VPN path cannot be reused after the system route changes.
        let redirectDelegate = ExitSummaryRedirectDelegate()
        let session = URLSession(
            configuration: Self.makeSessionConfiguration(),
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        return await resolveWithinBudget(using: Self.streamingLoader(session: session))
    }

    private func resolveWithinBudget(
        using loader: @escaping ExitSummaryDataLoader
    ) async -> ExitSummarySnapshot {
        await withTaskGroup(
            of: ExitSummarySnapshot?.self,
            returning: ExitSummarySnapshot.self
        ) { group in
            group.addTask { [loader] in
                await Self.resolveRequests(using: loader)
            }
            group.addTask { [resolveTimeoutNanoseconds] in
                do {
                    try await Task.sleep(nanoseconds: resolveTimeoutNanoseconds)
                    return .unavailable
                } catch {
                    return nil
                }
            }

            while let result = await group.next() {
                guard let result else { continue }
                group.cancelAll()
                return result
            }
            return .unavailable
        }
    }

    private static func resolveRequests(
        using loader: @escaping ExitSummaryDataLoader
    ) async -> ExitSummarySnapshot {
        // These two independent observations are always required and can run together. This
        // keeps the normal path within one request interval instead of serializing two timeouts.
        async let primaryLookup = loadSummaryCandidate(summaryURL, using: loader)
        async let verifierLookup = loadAddressCandidate(fallbackURLs[0], using: loader)
        let (primaryCandidate, verifierCandidate) = await (primaryLookup, verifierLookup)
        guard !Task.isCancelled else { return .unavailable }

        if let primaryCandidate {
            if verifierCandidate?.snapshot.address == primaryCandidate.snapshot.address {
                if primaryCandidate.hasCountry {
                    return primaryCandidate.snapshot
                }
                let secondaryCandidate = await loadSummaryCandidate(
                    secondarySummaryURL,
                    using: loader
                )
                guard !Task.isCancelled else { return .unavailable }
                if secondaryCandidate?.hasCountry == true,
                   secondaryCandidate?.snapshot.address == primaryCandidate.snapshot.address {
                    return secondaryCandidate!.snapshot
                }
                return ExitSummarySnapshot(
                    address: primaryCandidate.snapshot.address,
                    location: "国家/地区未知"
                )
            }
        }

        // ipify was already queried as the independent verifier, so never count it twice.
        let addressURLs = Array(fallbackURLs.dropFirst())
        let fallbackCandidates = await withTaskGroup(
            of: ParsedExitSummary?.self,
            returning: [ParsedExitSummary].self
        ) { group in
            group.addTask { [loader] in
                await loadSummaryCandidate(secondarySummaryURL, using: loader)
            }
            for url in addressURLs {
                group.addTask { [loader] in
                    await loadAddressCandidate(url, using: loader)
                }
            }

            var values: [ParsedExitSummary] = []
            for await value in group {
                if Task.isCancelled {
                    group.cancelAll()
                    return []
                }
                if let value {
                    values.append(value)
                }
            }
            return values
        }

        let candidates = [primaryCandidate, verifierCandidate].compactMap { $0 } + fallbackCandidates
        guard !Task.isCancelled,
              let address = selectConsensusAddress(candidates.map(\.snapshot.address)) else {
            return .unavailable
        }
        if let located = candidates.first(where: {
            $0.hasCountry && $0.snapshot.address == address
        }) {
            return located.snapshot
        }
        return ExitSummarySnapshot(address: address, location: "国家/地区未知")
    }

    private static func loadSummaryCandidate(
        _ url: URL,
        using loader: @escaping ExitSummaryDataLoader
    ) async -> ParsedExitSummary? {
        guard !Task.isCancelled,
              let data = try? await load(url, using: loader),
              !Task.isCancelled else {
            return nil
        }
        return parseSummaryCandidate(data)
    }

    private static func loadAddressCandidate(
        _ url: URL,
        using loader: @escaping ExitSummaryDataLoader
    ) async -> ParsedExitSummary? {
        guard !Task.isCancelled,
              let data = try? await load(url, using: loader),
              !Task.isCancelled,
              let rawValue = String(data: data, encoding: .utf8),
              let address = PublicIPAddress.normalize(rawValue) else {
            return nil
        }
        return ParsedExitSummary(
            snapshot: ExitSummarySnapshot(address: address, location: "国家/地区未知"),
            hasCountry: false
        )
    }

    static func parseSummaryResponse(_ data: Data) -> ExitSummarySnapshot? {
        parseSummaryCandidate(data)?.snapshot
    }

    private static func parseSummaryCandidate(_ data: Data) -> ParsedExitSummary? {
        guard data.count <= maximumResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              !isErrorResponse(root),
              let addressValue = firstNonEmpty(in: root, keys: ["ip"]),
              let address = PublicIPAddress.normalize(addressValue) else {
            return nil
        }

        let nestedLocation = root["location"] as? [String: Any]
        let country = firstNonEmpty(
            in: root,
            nested: nestedLocation,
            keys: ["country_name", "country", "country_code", "cc"]
        )
        let region = firstNonEmpty(in: root, nested: nestedLocation, keys: ["region", "region_name"])
        let city = firstNonEmpty(in: root, nested: nestedLocation, keys: ["city"])
        let location = composeLocation(country: country, region: region, city: city)
        return ParsedExitSummary(
            snapshot: ExitSummarySnapshot(address: address, location: location),
            hasCountry: country != nil
        )
    }

    static func selectConsensusAddress(_ candidates: [String]) -> String? {
        let normalized = candidates.compactMap(PublicIPAddress.normalize)
        let groups = Dictionary(grouping: normalized, by: { $0 })
            .map { (address: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.address < $1.address
            }

        guard let winner = groups.first,
              winner.count >= 2,
              winner.count * 2 > normalized.count else {
            return nil
        }
        return winner.address
    }

    private static func load(_ url: URL, using loader: ExitSummaryDataLoader) async throws -> Data {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 8
        )
        request.httpMethod = "GET"
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("application/json, text/plain;q=0.9", forHTTPHeaderField: "Accept")

        let (data, response) = try await loader(request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.url == url,
              (200...299).contains(httpResponse.statusCode),
              data.count <= maximumResponseBytes else {
            throw ExitSummaryError.invalidResponse
        }
        return data
    }

    private static func streamingLoader(session: URLSession) -> ExitSummaryDataLoader {
        { request in
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.url == request.url,
                  (200...299).contains(httpResponse.statusCode),
                  httpResponse.expectedContentLength <= 0 ||
                    httpResponse.expectedContentLength <= Int64(maximumResponseBytes) else {
                throw ExitSummaryError.invalidResponse
            }

            var data = Data()
            data.reserveCapacity(min(
                maximumResponseBytes,
                max(0, Int(httpResponse.expectedContentLength))
            ))
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw ExitSummaryError.invalidResponse
                }
                data.append(byte)
            }
            return (data, response)
        }
    }

    private static func firstNonEmpty(
        in root: [String: Any],
        nested: [String: Any]? = nil,
        keys: [String]
    ) -> String? {
        for source in [root, nested].compactMap({ $0 }) {
            for key in keys {
                guard let value = source[key] as? String,
                      let normalized = normalizedLocationText(value) else {
                    continue
                }
                return normalized
            }
        }
        return nil
    }

    private static func composeLocation(
        country: String?,
        region: String?,
        city: String?
    ) -> String {
        guard let country else { return "国家/地区未知" }
        var components = [country, region, city].compactMap { $0 }
        var seen = Set<String>()
        components = components.filter { seen.insert($0.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )).inserted }
        let joined = components.joined(separator: " · ")
        guard joined.unicodeScalars.count > maximumCombinedLocationCharacters else { return joined }
        var bounded = ""
        var scalarCount = 0
        for character in joined {
            let characterScalars = character.unicodeScalars.count
            guard scalarCount + characterScalars < maximumCombinedLocationCharacters else { break }
            bounded.append(character)
            scalarCount += characterScalars
        }
        return bounded + "…"
    }

    private static func normalizedLocationText(_ value: String) -> String? {
        guard value.unicodeScalars.allSatisfy({ scalar in
            if CharacterSet.controlCharacters.contains(scalar) {
                return CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
            return ![0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                     0x2066, 0x2067, 0x2068, 0x2069].contains(scalar.value)
        }) else { return nil }
        let normalized = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.isEmpty || normalized.unicodeScalars.count > maximumLocationCharacters
            ? nil
            : normalized
    }

    private static func isErrorResponse(_ root: [String: Any]) -> Bool {
        if let success = root["success"] {
            guard let flag = success as? Bool, flag else { return true }
        }
        guard let value = root["error"], !(value is NSNull) else {
            return false
        }
        if let value = root["error"] as? Bool {
            return value
        }
        if let value = root["error"] as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalized.isEmpty && !["false", "0", "no"].contains(normalized)
        }
        if let value = value as? NSNumber {
            return value.doubleValue != 0
        }
        return true
    }

    private enum ExitSummaryError: Error {
        case invalidResponse
    }
}

enum PublicIPAddress {
    static func normalize(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("\0"),
              !value.contains("%"),
              !value.hasPrefix("["),
              !value.hasSuffix("]") else {
            return nil
        }

        if isStrictIPv4(value) {
            var address = in_addr()
            guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
                return nil
            }
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            guard isPublicIPv4(bytes) else { return nil }
            return render(address: &address, family: AF_INET, bufferSize: Int(INET_ADDRSTRLEN))
        }

        guard value.contains(":") else { return nil }
        if value.contains("."),
           let separator = value.lastIndex(of: ":"),
           !isStrictIPv4(String(value[value.index(after: separator)...])) {
            return nil
        }

        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        if isIPv4Mapped(bytes) {
            let mapped = Array(bytes.suffix(4))
            guard isPublicIPv4(mapped) else { return nil }
            return mapped.map(String.init).joined(separator: ".")
        }
        guard isPublicIPv6(bytes) else { return nil }
        return render(address: &address, family: AF_INET6, bufferSize: Int(INET6_ADDRSTRLEN))
    }

    private static func isStrictIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            let bytes = Array(octet.utf8)
            return !bytes.isEmpty &&
                bytes.count <= 3 &&
                bytes.allSatisfy { (48...57).contains($0) } &&
                !(bytes.count > 1 && bytes[0] == 48) &&
                bytes.reduce(0) { ($0 * 10) + Int($1 - 48) } <= 255
        }
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 0 && bytes[2] == 0 { return false }
        if first == 192 && second == 0 && bytes[2] == 2 { return false }
        if first == 192 && second == 31 && bytes[2] == 196 { return false }
        if first == 192 && second == 52 && bytes[2] == 193 { return false }
        if first == 192 && second == 88 && bytes[2] == 99 { return false }
        if first == 192 && second == 168 { return false }
        if first == 192 && second == 175 && bytes[2] == 48 { return false }
        if first == 198 && (second == 18 || second == 19) { return false }
        if first == 198 && second == 51 && bytes[2] == 100 { return false }
        if first == 203 && second == 0 && bytes[2] == 113 { return false }
        return true
    }

    private static func isIPv4Mapped(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 &&
            bytes.prefix(10).allSatisfy { $0 == 0 } &&
            bytes[10] == 0xFF && bytes[11] == 0xFF
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16,
              bytes[0] & 0xE0 == 0x20 else {
            return false
        }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 0x02 { return false }
        if bytes[0...3].elementsEqual([0x20, 0x01, 0x0D, 0xB8]) { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
        if bytes[0...5].elementsEqual([0x26, 0x20, 0x00, 0x4F, 0x80, 0x00]) { return false }
        if bytes[0] == 0x3F && bytes[1] == 0xFF && bytes[2] & 0xF0 == 0 { return false }
        return true
    }

    private static func render<T>(
        address: inout T,
        family: Int32,
        bufferSize: Int
    ) -> String? {
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let result = withUnsafePointer(to: &address) { addressPointer in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                inet_ntop(
                    family,
                    UnsafeRawPointer(addressPointer),
                    bufferPointer.baseAddress,
                    socklen_t(bufferSize)
                )
            }
        }
        guard result != nil else { return nil }
        return String(cString: buffer)
    }
}

struct RefreshGenerationGate: Sendable {
    private(set) var current: UInt64 = 0

    mutating func request() -> UInt64 {
        current &+= 1
        return current
    }

    func accepts(_ generation: UInt64) -> Bool {
        generation == current
    }
}
