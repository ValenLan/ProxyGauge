import Foundation

@main
struct ExitSummaryServiceCheck {
    static func main() async throws {
        try checkPublicAddressNormalization()
        try checkSummaryParsing()
        try checkConsensusSelection()
        try checkGenerationGate()
        try checkPersistence()
        try checkEphemeralConfiguration()
        try await checkPrimarySummaryPath()
        try await checkPrimaryAndVerifierRunConcurrently()
        try await checkPrimarySummaryRequiresIndependentConfirmation()
        try await checkPartialPrimaryUsesCountryFallback()
        try await checkConcurrentFallbackConsensus()
        try await checkFallbackTieAndInvalidValues()
        try await checkResponseBoundaryAndRedirectRejection()
        try await checkCancellationStopsFallbacks()
        try await checkTotalResolveBudget()
        if ProcessInfo.processInfo.environment["PROXYGAUGE_LIVE_EXIT_TEST"] == "1" {
            try await checkLiveSystemRoute()
        }
        print("ProxyGauge system-path exit summary tests passed.")
    }

    private static func checkPublicAddressNormalization() throws {
        try require(PublicIPAddress.normalize("8.8.8.8\n") == "8.8.8.8", "Public IPv4 must normalize.")
        try require(PublicIPAddress.normalize("008.8.8.8") == nil, "IPv4 leading zeroes must be rejected.")
        try require(PublicIPAddress.normalize("10.0.0.1") == nil, "Private IPv4 must be rejected.")
        try require(PublicIPAddress.normalize("100.64.0.1") == nil, "CGNAT IPv4 must be rejected.")
        try require(PublicIPAddress.normalize("203.0.113.8") == nil, "Documentation IPv4 must be rejected.")
        try require(PublicIPAddress.normalize("192.31.196.1") == nil, "AS112 IPv4 must be rejected.")
        try require(PublicIPAddress.normalize("192.52.193.1") == nil, "AMT IPv4 must be rejected.")
        try require(PublicIPAddress.normalize("192.175.48.1") == nil, "Direct AS112 IPv4 must be rejected.")
        try require(PublicIPAddress.normalize("127.0.0.1") == nil, "Loopback IPv4 must be rejected.")

        try require(
            PublicIPAddress.normalize("2606:4700:4700:0:0:0:0:1111") == "2606:4700:4700::1111",
            "Equivalent public IPv6 spellings must canonicalize."
        )
        try require(PublicIPAddress.normalize("::ffff:8.8.8.8") == "8.8.8.8", "Mapped public IPv4 must compare as IPv4.")
        try require(PublicIPAddress.normalize("::ffff:10.0.0.1") == nil, "Mapped private IPv4 must be rejected.")
        try require(PublicIPAddress.normalize("fc00::1") == nil, "Unique-local IPv6 must be rejected.")
        try require(PublicIPAddress.normalize("fe80::1") == nil, "Link-local IPv6 must be rejected.")
        try require(PublicIPAddress.normalize("2001:db8::1") == nil, "Documentation IPv6 must be rejected.")
        try require(PublicIPAddress.normalize("2001:2::1") == nil, "Benchmarking IPv6 must be rejected.")
        try require(PublicIPAddress.normalize("2001:10::1") == nil, "ORCHIDv1 IPv6 must be rejected.")
        try require(PublicIPAddress.normalize("2001:20::1") == nil, "ORCHIDv2 IPv6 must be rejected.")
        try require(PublicIPAddress.normalize("2001:1::1") == nil, "Protocol-anycast IPv6 must be rejected.")
        try require(PublicIPAddress.normalize("2001:3::1") == nil, "AMT IPv6 must be rejected.")
        try require(PublicIPAddress.normalize("2002::1") == nil, "6to4 IPv6 must be rejected.")
        try require(PublicIPAddress.normalize("2620:4f:8000::1") == nil, "AS112 IPv6 must be rejected.")
        try require(PublicIPAddress.normalize("3fff::1") == nil, "Additional documentation IPv6 must be rejected.")
        try require(PublicIPAddress.normalize("2606:4700:4700::1111%en0") == nil, "Scoped IPv6 must be rejected.")
    }

    private static func checkSummaryParsing() throws {
        let full = Data(#"""
        {
          "ip":"8.8.8.8",
          "country_name":"  United   States  ",
          "country":"US",
          "region":"California",
          "city":"Mountain View"
        }
        """#.utf8)
        try require(
            SystemExitSummaryService.parseSummaryResponse(full) == ExitSummarySnapshot(
                address: "8.8.8.8",
                location: "United States · California · Mountain View"
            ),
            "Country, region, and city must be normalized and combined."
        )

        let countryFallback = Data(#"""
        {
          "ip":"1.1.1.1",
          "country_name":" ",
          "country":"",
          "country_code":"AU",
          "cc":"ZZ",
          "region":"Queensland",
          "city":"Brisbane"
        }
        """#.utf8)
        try require(
            SystemExitSummaryService.parseSummaryResponse(countryFallback)?.location == "AU · Queensland · Brisbane",
            "The first non-empty supported country field must win."
        )

        let missingCountry = Data(#"{"ip":"9.9.9.9","city":"Los Angeles"}"#.utf8)
        try require(
            SystemExitSummaryService.parseSummaryResponse(missingCountry)?.location == "国家/地区未知",
            "Region and city must not be displayed without a country."
        )

        let nestedAndQuoted = Data(#"""
        {
          "ip":"1.0.0.1",
          "location":{"country":"Antigua and Barbuda","region":"Saint John","city":"St. John's"}
        }
        """#.utf8)
        try require(
            SystemExitSummaryService.parseSummaryResponse(nestedAndQuoted)?.location ==
                "Antigua and Barbuda · Saint John · St. John's",
            "Location punctuation must be preserved without shell tokenization."
        )

        let duplicate = Data(#"{"ip":"8.8.4.4","country_name":"Singapore","region":"Singapore","city":"Singapore"}"#.utf8)
        try require(
            SystemExitSummaryService.parseSummaryResponse(duplicate)?.location == "Singapore",
            "Repeated location components must be de-duplicated."
        )

        try require(
            SystemExitSummaryService.parseSummaryResponse(Data(#"["8.8.8.8"]"#.utf8)) == nil,
            "A non-object JSON root must fail safely."
        )
        try require(
            SystemExitSummaryService.parseSummaryResponse(Data(#"{"ip":"192.168.1.2","country_name":"Private"}"#.utf8)) == nil,
            "A non-public summary address must be rejected."
        )
        try require(
            SystemExitSummaryService.parseSummaryResponse(Data(#"{"error":true,"ip":"8.8.8.8","country_name":"United States"}"#.utf8)) == nil,
            "An upstream error document must never be treated as a valid summary."
        )
        try require(
            SystemExitSummaryService.parseSummaryResponse(Data(#"{"error":"true","ip":"8.8.8.8","country_name":"United States"}"#.utf8)) == nil,
            "A string-valued upstream error flag must also fail closed."
        )
        try require(
            SystemExitSummaryService.parseSummaryResponse(Data(#"{"error":1,"ip":"8.8.8.8","country_name":"United States"}"#.utf8)) == nil,
            "A numeric upstream error flag must fail closed."
        )
        try require(
            SystemExitSummaryService.parseSummaryResponse(Data(#"{"error":{"reason":"blocked"},"ip":"8.8.8.8"}"#.utf8)) == nil,
            "An unknown structured upstream error flag must fail closed."
        )

        let normalizedRegion = Data(#"{"ip":"8.8.4.4","country_name":"New   Zealand","region_name":" Auckland \n Region ","city":"Auckland"}"#.utf8)
        try require(
            SystemExitSummaryService.parseSummaryResponse(normalizedRegion)?.location ==
                "New Zealand · Auckland Region · Auckland",
            "Location whitespace and region_name fallback must normalize consistently."
        )

        let oversizedCity = Data(
            "{\"ip\":\"8.8.4.4\",\"country_name\":\"Canada\",\"city\":\"\(String(repeating: "x", count: 129))\"}".utf8
        )
        try require(
            SystemExitSummaryService.parseSummaryResponse(oversizedCity)?.location == "Canada",
            "An oversized location field must not expand the dashboard indefinitely."
        )

        let longCombinedLocation = Data(
            "{\"ip\":\"8.8.4.4\",\"country_name\":\"\(String(repeating: "a", count: 60))\",\"region\":\"\(String(repeating: "b", count: 60))\",\"city\":\"\(String(repeating: "c", count: 60))\"}".utf8
        )
        let boundedLocation = SystemExitSummaryService.parseSummaryResponse(longCombinedLocation)?.location
        try require(
            boundedLocation?.count == 160 && boundedLocation?.hasSuffix("…") == true,
            "The combined location must remain bounded even when every component is individually valid."
        )

        let bidiLocation = Data(#"{"ip":"8.8.4.4","country_name":"Canada","city":"safe\u202Etxt"}"#.utf8)
        try require(
            SystemExitSummaryService.parseSummaryResponse(bidiLocation)?.location == "Canada",
            "Bidirectional control characters from an upstream location must not reach the UI."
        )

        let numericCountry = Data(#"{"ip":"8.8.4.4","country_name":840,"city":"Mountain View"}"#.utf8)
        try require(
            SystemExitSummaryService.parseSummaryResponse(numericCountry)?.location == "国家/地区未知",
            "Non-string country metadata must not masquerade as a complete country result."
        )

        let combiningFlood = "a" + String(repeating: "\u{0301}", count: 512)
        let combiningLocation = Data(
            "{\"ip\":\"8.8.4.4\",\"country_name\":\"Canada\",\"city\":\"\(combiningFlood)\"}".utf8
        )
        try require(
            SystemExitSummaryService.parseSummaryResponse(combiningLocation)?.location == "Canada",
            "Combining marks must count toward the location resource limit."
        )
    }

    private static func checkPartialPrimaryUsesCountryFallback() async throws {
        let secondaryURL = "https://ipwho.is/?fields=success,ip,country,country_code,region,city"
        let loader = ScriptedExitLoader(replies: [
            "https://ipapi.co/json/": .success(#"{"ip":"8.8.8.8","city":"Ashburn"}"#),
            secondaryURL: .success(#"{"success":true,"ip":"8.8.8.8","country":"United States","region":"Virginia","city":"Ashburn"}"#),
            "https://api.ipify.org": .success("8.8.8.8"),
            "https://ifconfig.me/ip": .success("8.8.8.8"),
            "https://ip.sb/ip": .success("1.1.1.1")
        ])
        let service = SystemExitSummaryService(loader: { request in
            try await loader.load(request)
        })
        let summary = await service.resolve()
        try require(
            summary == ExitSummarySnapshot(
                address: "8.8.8.8",
                location: "United States · Virginia · Ashburn"
            ),
            "A city-only primary response must use a matching country-bearing fallback."
        )
    }

    private static func checkConsensusSelection() throws {
        try require(
            SystemExitSummaryService.selectConsensusAddress(["8.8.8.8", "8.8.8.8\n", "1.1.1.1"]) == "8.8.8.8",
            "A unique two-of-three public-IP majority must win."
        )
        try require(
            SystemExitSummaryService.selectConsensusAddress([
                "2606:4700:4700:0:0:0:0:1111",
                "2606:4700:4700::1111",
                "2001:4860:4860::8888"
            ]) == "2606:4700:4700::1111",
            "Equivalent IPv6 values must vote together."
        )
        try require(
            SystemExitSummaryService.selectConsensusAddress(["8.8.8.8", "1.1.1.1"]) == nil,
            "A one-to-one tie must not choose an arbitrary address."
        )
        try require(
            SystemExitSummaryService.selectConsensusAddress(["8.8.8.8"]) == nil,
            "One fallback response is insufficient for consistency."
        )
        try require(
            SystemExitSummaryService.selectConsensusAddress([
                "8.8.8.8", "8.8.8.8", "1.1.1.1", "9.9.9.9"
            ]) == nil,
            "A unique plurality that is only half of the valid observations is not a strict majority."
        )
        try require(
            SystemExitSummaryService.selectConsensusAddress([
                "8.8.8.8", "8.8.8.8", "8.8.8.8", "1.1.1.1", "9.9.9.9"
            ]) == "8.8.8.8",
            "More than half of the valid independent observations must form a strict majority."
        )
        try require(
            SystemExitSummaryService.selectConsensusAddress(["10.0.0.1", "10.0.0.1"]) == nil,
            "Non-public candidates must not form a majority."
        )
    }

    private static func checkGenerationGate() throws {
        var gate = RefreshGenerationGate()
        let first = gate.request()
        try require(gate.accepts(first), "The current refresh generation must be accepted.")
        let second = gate.request()
        try require(!gate.accepts(first), "A queued refresh must invalidate the older generation immediately.")
        try require(gate.accepts(second), "The newest refresh generation must be accepted.")
    }

    private static func checkPersistence() throws {
        let suiteName = "com.valenlan.proxygauge.exit-cache-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure(message: "Could not create isolated exit-summary preferences.")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try require(ExitSummaryPersistence.loadSummary(defaults: defaults) == nil,
                    "A fresh install must not fabricate an exit summary.")
        ExitSummaryPersistence.recordPathFingerprint(
            String(repeating: "a", count: 64), clearSummary: false, defaults: defaults)
        ExitSummaryPersistence.saveSummary(
            .init(address: "8.8.8.8", location: "United States"), defaults: defaults)
        try require(
            ExitSummaryPersistence.loadSummary(defaults: defaults) ==
                .init(address: "8.8.8.8", location: "United States"),
            "A verified public exit must survive reopening without another public lookup."
        )
        try require(
            ExitSummaryPersistence.loadPathFingerprint(defaults: defaults) ==
                String(repeating: "a", count: 64),
            "The local path fingerprint must survive reopening."
        )

        ExitSummaryPersistence.recordPathFingerprint(
            String(repeating: "b", count: 64), clearSummary: true, defaults: defaults)
        try require(ExitSummaryPersistence.loadSummary(defaults: defaults) == nil,
                    "A changed local path must clear the stale cached exit before lookup.")
        defaults.set("10.0.0.1", forKey: "proxygauge.exit-summary.address.v1")
        defaults.set("Private", forKey: "proxygauge.exit-summary.location.v1")
        try require(ExitSummaryPersistence.loadSummary(defaults: defaults) == nil,
                    "A tampered non-public cached address must fail closed.")
    }

    private static func checkEphemeralConfiguration() throws {
        let configuration = SystemExitSummaryService.makeSessionConfiguration()
        try require(configuration.urlCache == nil, "Exit lookups must not use a URL cache.")
        try require(configuration.httpCookieStorage == nil, "Exit lookups must not retain cookies.")
        try require(configuration.urlCredentialStorage == nil, "Exit lookups must not read retained credentials.")
        try require(
            configuration.requestCachePolicy == .reloadIgnoringLocalCacheData,
            "Exit requests must ignore cached responses."
        )
        try require(!configuration.waitsForConnectivity, "A failed path must time out instead of retaining stale UI state.")
    }

    private static func checkPrimarySummaryPath() async throws {
        let loader = ScriptedExitLoader(replies: [
            "https://ipapi.co/json/": .success(#"{"ip":"8.8.8.8","country_name":"United States","region":"Virginia","city":"Ashburn"}"#),
            "https://api.ipify.org": .success("8.8.8.8")
        ])
        let service = SystemExitSummaryService(loader: { request in
            try await loader.load(request)
        })
        let summary = await service.resolve()
        try require(summary.address == "8.8.8.8", "The valid primary summary must be used.")
        try require(summary.location == "United States · Virginia · Ashburn", "Primary location fields must survive.")
        let requests = await loader.recordedRequests()
        try require(requests.count == 2, "A valid primary summary must still receive one independent IP confirmation.")
        try require(
            requests[0].cachePolicy == .reloadIgnoringLocalCacheData &&
                requests[0].value(forHTTPHeaderField: "Cache-Control")?.contains("no-store") == true,
            "The primary request must explicitly bypass caches."
        )
    }

    private static func checkPrimaryAndVerifierRunConcurrently() async throws {
        let loader = ScriptedExitLoader(replies: [
            "https://ipapi.co/json/": .success(
                #"{"ip":"8.8.8.8","country_name":"United States"}"#,
                delayMilliseconds: 100
            ),
            "https://api.ipify.org": .success("8.8.8.8", delayMilliseconds: 100)
        ])
        let service = SystemExitSummaryService(loader: { request in
            try await loader.load(request)
        })
        let summary = await service.resolve()
        try require(summary.address == "8.8.8.8", "The concurrently confirmed primary address must be used.")
        let maximumConcurrentRequests = await loader.maximumConcurrentRequests()
        try require(
            maximumConcurrentRequests == 2,
            "The primary summary and its independent verifier must not consume two serial request intervals."
        )
    }

    private static func checkPrimarySummaryRequiresIndependentConfirmation() async throws {
        let loader = ScriptedExitLoader(replies: [
            "https://ipapi.co/json/": .success(
                #"{"ip":"8.8.8.8","country_name":"United States","city":"Ashburn"}"#
            ),
            "https://api.ipify.org": .success("1.1.1.1"),
            "https://ipwho.is/?fields=success,ip,country,country_code,region,city": .success(
                #"{"success":true,"ip":"1.1.1.1","country":"Australia","city":"Sydney"}"#
            ),
            "https://ifconfig.me/ip": .success("1.1.1.1"),
            "https://ip.sb/ip": .success("8.8.8.8")
        ])
        let service = SystemExitSummaryService(loader: { request in
            try await loader.load(request)
        })
        let summary = await service.resolve()
        try require(
            summary == ExitSummarySnapshot(
                address: "1.1.1.1",
                location: "Australia · Sydney"
            ),
            "A conflicting primary response must lose to the strict independent consensus."
        )
    }

    private static func checkConcurrentFallbackConsensus() async throws {
        let loader = BarrierExitLoader(bodies: [
            "https://ipwho.is/?fields=success,ip,country,country_code,region,city":
                #"{"success":true,"ip":"2606:4700:4700::1111","country":"United States","region":"California","city":"Los Angeles"}"#,
            "https://api.ipify.org": "2606:4700:4700:0:0:0:0:1111",
            "https://ifconfig.me/ip": "2606:4700:4700::1111\n",
            "https://ip.sb/ip": "2001:4860:4860::8888"
        ])
        let service = SystemExitSummaryService(loader: { request in
            try await loader.load(request)
        })
        let summary = await service.resolve()
        try require(summary.address == "2606:4700:4700::1111", "Canonical two-of-three fallback consensus must win.")
        try require(summary.location == "United States · California · Los Angeles", "A matching geolocation fallback must supply country, region, and city.")
        let fallbackStartCount = await loader.fallbackStartCount()
        let requestCount = await loader.recordedRequests().count
        try require(fallbackStartCount == 4, "All fallback requests must start before any fallback is released.")
        try require(requestCount == 5, "The invalid primary response must trigger the geolocation and IP fallbacks.")
        let requests = await loader.recordedRequests()
        try require(
            requests.allSatisfy {
                $0.cachePolicy == .reloadIgnoringLocalCacheData &&
                    $0.value(forHTTPHeaderField: "Cache-Control")?.contains("no-store") == true &&
                    $0.value(forHTTPHeaderField: "Pragma") == "no-cache"
            },
            "Every exit lookup must explicitly bypass client and intermediary caches."
        )
    }

    private static func checkFallbackTieAndInvalidValues() async throws {
        let tieLoader = ScriptedExitLoader(replies: [
            "https://ipapi.co/json/": .failure(status: 503),
            "https://ipwho.is/?fields=success,ip,country,country_code,region,city": .failure(status: 503),
            "https://api.ipify.org": .success("8.8.8.8"),
            "https://ifconfig.me/ip": .success("1.1.1.1"),
            "https://ip.sb/ip": .success("9.9.9.9")
        ])
        let tieService = SystemExitSummaryService(loader: { request in
            try await tieLoader.load(request)
        })
        let tieSummary = await tieService.resolve()
        try require(tieSummary == .unavailable, "A three-way tie must produce an unavailable state.")

        let invalidLoader = ScriptedExitLoader(replies: [
            "https://ipapi.co/json/": .success(#"{"ip":"127.0.0.1","city":"Local"}"#),
            "https://ipwho.is/?fields=success,ip,country,country_code,region,city":
                .success(#"{"success":false,"ip":"8.8.8.8","country":"United States"}"#),
            "https://api.ipify.org": .success("192.168.1.2"),
            "https://ifconfig.me/ip": .success("203.0.113.4"),
            "https://ip.sb/ip": .success("not-an-ip")
        ])
        let invalidService = SystemExitSummaryService(loader: { request in
            try await invalidLoader.load(request)
        })
        let invalidSummary = await invalidService.resolve()
        try require(invalidSummary == .unavailable, "Private, reserved, and malformed values must all fail.")
    }

    private static func checkResponseBoundaryAndRedirectRejection() async throws {
        let oversizedPrimary = #"{"ip":"8.8.8.8","country_name":"United States","padding":""# +
            String(repeating: "x", count: 64 * 1024) + #""}"#
        let oversizedLoader = ScriptedExitLoader(replies: [
            "https://ipapi.co/json/": .success(oversizedPrimary),
            "https://api.ipify.org": .success("8.8.8.8"),
            "https://ipwho.is/?fields=success,ip,country,country_code,region,city":
                .success(#"{"success":true,"ip":"1.1.1.1","country":"Australia"}"#),
            "https://ifconfig.me/ip": .success("1.1.1.1"),
            "https://ip.sb/ip": .success("8.8.8.8")
        ])
        let oversizedService = SystemExitSummaryService(loader: { request in
            try await oversizedLoader.load(request)
        })
        let oversizedResult = await oversizedService.resolve()
        try require(
            oversizedResult == .unavailable,
            "An oversized primary document must be rejected instead of turning a tied remainder into a result."
        )

        let redirectedPrimary = URL(string: "https://redirect.invalid/result")!
        let redirectLoader = ScriptedExitLoader(replies: [
            "https://ipapi.co/json/": .success(
                #"{"ip":"8.8.8.8","country_name":"United States"}"#,
                responseURL: redirectedPrimary
            ),
            "https://api.ipify.org": .success("8.8.8.8"),
            "https://ipwho.is/?fields=success,ip,country,country_code,region,city":
                .success(#"{"success":true,"ip":"1.1.1.1","country":"Australia"}"#),
            "https://ifconfig.me/ip": .success("1.1.1.1"),
            "https://ip.sb/ip": .success("8.8.8.8")
        ])
        let redirectService = SystemExitSummaryService(loader: { request in
            try await redirectLoader.load(request)
        })
        let redirectResult = await redirectService.resolve()
        try require(
            redirectResult == .unavailable,
            "A response whose final URL differs from the requested endpoint must fail closed."
        )
    }

    private static func checkCancellationStopsFallbacks() async throws {
        let loader = BlockingExitLoader()
        let service = SystemExitSummaryService(loader: { request in
            try await loader.load(request)
        })
        let task = Task { await service.resolve() }
        await loader.waitUntilStarted(minimumRequestCount: 2)
        task.cancel()
        let result = await task.value
        try require(result == .unavailable, "A canceled lookup must return an unavailable result.")
        let requestCount = await loader.requestCount()
        try require(
            requestCount == 2,
            "Cancellation may stop the concurrent primary pair but must not start second-stage fallbacks."
        )
    }

    private static func checkTotalResolveBudget() async throws {
        let loader = BlockingExitLoader()
        let service = SystemExitSummaryService(
            loader: { request in try await loader.load(request) },
            resolveTimeoutNanoseconds: 100_000_000
        )
        let startedAt = ContinuousClock.now
        let result = await service.resolve()
        let elapsed = ContinuousClock.now - startedAt
        let requestCount = await loader.requestCount()
        try require(result == .unavailable, "An exhausted total lookup budget must produce an unavailable result.")
        try require(elapsed < .seconds(2), "The total lookup budget must cancel stalled requests promptly.")
        try require(
            requestCount == 2,
            "A total timeout during the concurrent primary pair must not launch fallback traffic."
        )
    }

    private static func checkLiveSystemRoute() async throws {
        let summary = await SystemExitSummaryService().resolve()
        try require(
            PublicIPAddress.normalize(summary.address) == summary.address,
            "The live system route must produce one canonical public exit address."
        )
        print("ProxyGauge live macOS system-route lookup passed without printing the address.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message: message) }
    }
}

private actor ScriptedExitLoader {
    struct Reply: Sendable {
        let status: Int
        let body: Data
        let delayMilliseconds: Int
        let responseURL: URL?

        static func success(
            _ body: String,
            delayMilliseconds: Int = 0,
            responseURL: URL? = nil
        ) -> Reply {
            Reply(
                status: 200,
                body: Data(body.utf8),
                delayMilliseconds: delayMilliseconds,
                responseURL: responseURL
            )
        }

        static func failure(status: Int) -> Reply {
            Reply(status: status, body: Data(), delayMilliseconds: 0, responseURL: nil)
        }
    }

    private let replies: [String: Reply]
    private var requests: [URLRequest] = []
    private var activeRequests = 0
    private var maximumActiveRequests = 0

    init(replies: [String: Reply]) {
        self.replies = replies
    }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              let reply = replies[url.absoluteString] else {
            throw TestFailure(message: "Unexpected URL: \(request.url?.absoluteString ?? "nil")")
        }
        requests.append(request)
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        if reply.delayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(reply.delayMilliseconds))
        }
        activeRequests -= 1
        guard let response = HTTPURLResponse(
            url: reply.responseURL ?? url,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Cache-Control": "public, max-age=3600"]
        ) else {
            throw TestFailure(message: "Could not build test HTTP response.")
        }
        return (reply.body, response)
    }

    func recordedRequests() -> [URLRequest] { requests }
    func maximumConcurrentRequests() -> Int { maximumActiveRequests }
}

private actor BarrierExitLoader {
    private let bodies: [String: String]
    private var requests: [URLRequest] = []
    private var startedFallbacks = 0
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(bodies: [String: String]) {
        self.bodies = bodies
    }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else {
            throw TestFailure(message: "Barrier loader received a request without a URL.")
        }
        requests.append(request)
        if url.absoluteString == "https://ipapi.co/json/" {
            return try response(for: url, body: #"["not-an-object"]"#)
        }
        guard let body = bodies[url.absoluteString] else {
            throw TestFailure(message: "Unexpected fallback URL: \(url.absoluteString)")
        }

        startedFallbacks += 1
        if url.absoluteString == "https://api.ipify.org" {
            return try response(for: url, body: body)
        }
        if startedFallbacks == bodies.count {
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        } else {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return try response(for: url, body: body)
    }

    func fallbackStartCount() -> Int { startedFallbacks }
    func recordedRequests() -> [URLRequest] { requests }

    private func response(for url: URL, body: String) throws -> (Data, URLResponse) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            throw TestFailure(message: "Could not build barrier HTTP response.")
        }
        return (Data(body.utf8), response)
    }
}

private actor BlockingExitLoader {
    private var requests = 0
    private struct StartWaiter {
        let minimumRequestCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }
    private var startWaiters: [StartWaiter] = []

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        let ready = startWaiters.filter { requests >= $0.minimumRequestCount }
        startWaiters.removeAll { requests >= $0.minimumRequestCount }
        ready.forEach { $0.continuation.resume() }
        try await Task.sleep(for: .seconds(60))
        throw TestFailure(message: "A canceled blocking request unexpectedly resumed.")
    }

    func waitUntilStarted(minimumRequestCount: Int = 1) async {
        if requests >= minimumRequestCount { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(StartWaiter(
                minimumRequestCount: minimumRequestCount,
                continuation: continuation
            ))
        }
    }

    func requestCount() -> Int { requests }
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
