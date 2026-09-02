import Foundation

@main
struct LocalEndpointPolicyCheck {
    static func main() throws {
        try require(LocalEndpointPolicy.normalize("localhost:7890") == "127.0.0.1:7890")
        try require(LocalEndpointPolicy.normalize("127.42.0.9:7890") == "127.42.0.9:7890")
        try require(LocalEndpointPolicy.normalize("[::1]:7890") == "[::1]:7890")
        try require(LocalEndpointPolicy.normalize("::1:7890") == "[::1]:7890")
        try require(LocalEndpointPolicy.normalize("192.0.2.1:7890") == nil)
        try require(LocalEndpointPolicy.normalize("example.com:7890") == nil)
        try require(LocalEndpointPolicy.normalize("[fe80::1]:7890") == nil)
        try require(LocalEndpointPolicy.normalize("127.0.0.1:0") == nil)
        print("ProxyGauge local endpoint policy tests passed.")
    }

    private static func require(_ condition: @autoclosure () -> Bool) throws {
        if !condition() { throw CheckError.failed }
    }

    private enum CheckError: Error { case failed }
}
