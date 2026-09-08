import Foundation
import Testing
@testable import LiveryCore

/// Icon URLs are chosen by whoever uploaded the catalog entry, so the downloader refuses anything that is not plain
/// HTTPS to a routable host.
struct NetworkGuardTests {
    @Test func plainHTTPSIsAccepted() throws {
        try HTTP.validate(URL(string: "https://icons.example.com/a.png"))
    }

    @Test func nonHTTPSIsRefused() {
        for bad in ["http://icons.example.com/a.png", "file:///etc/passwd", "ftp://example.com/a.png"] {
            #expect(throws: (any Error).self) { try HTTP.validate(URL(string: bad)) }
        }
    }

    @Test func localAndPrivateAddressesAreRefused() {
        for host in ["localhost", "127.0.0.1", "10.1.2.3", "192.168.0.5", "172.16.0.1", "172.31.255.255",
                     "169.254.1.1", "printer.local", "::1", "::ffff:127.0.0.1", "::ffff:10.0.0.9", "fd00::1",
                     "fe80::1%en0"] {
            #expect(HTTP.isLocal(host), "\(host) should count as local")
            #expect(throws: (any Error).self) { try HTTP.validate(URL(string: "https://\(host)/icon.png")) }
        }
    }

    @Test func routableAddressesAreAllowed() {
        for host in ["icons.ahmetdedeler.com", "api.macosicons.com", "8.8.8.8", "172.32.0.1", "11.0.0.1"] {
            #expect(!HTTP.isLocal(host), "\(host) should be routable")
        }
    }

    @Test func aNameIsJudgedByWhatItResolvesTo() {
        // localhost is in /etc/hosts, so this needs no network. The literal check catches the name; the resolution
        // check is what would catch a public name that someone has pointed at a loopback or private address.
        let addresses = HTTP.resolve("localhost")
        #expect(!addresses.isEmpty)
        #expect(addresses.allSatisfy(HTTP.isLocal))
    }
}
