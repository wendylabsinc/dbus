import Testing

@testable import DBUS

@Suite
struct DBusAddressTests {
  @Test func parseUnixPathAddress() throws {
    let address = try DBusAddress.parse("unix:path=/tmp/dbus-test")
    guard case .unix(let path) = address else {
      #expect(Bool(false), "Expected unix address")
      return
    }
    #expect(path == "/tmp/dbus-test")
  }

  @Test func parsePercentEncodedUnixPath() throws {
    let address = try DBusAddress.parse("unix:path=%2Ftmp%2Fdbus-test")
    guard case .unix(let path) = address else {
      #expect(Bool(false), "Expected unix address")
      return
    }
    #expect(path == "/tmp/dbus-test")
  }

  @Test func parseSkipsUnsupportedTransports() throws {
    let address = try DBusAddress.parse("autolaunch:guid=abcd;unix:path=/tmp/dbus-test")
    guard case .unix(let path) = address else {
      #expect(Bool(false), "Expected unix address")
      return
    }
    #expect(path == "/tmp/dbus-test")
  }

  @Test func parseTcpIpv4Address() throws {
    let address = try DBusAddress.parse("tcp:host=127.0.0.1,port=5555")
    guard case .tcp(let host, let port, let family) = address else {
      #expect(Bool(false), "Expected tcp address")
      return
    }
    #expect(host == "127.0.0.1")
    #expect(port == 5555)
    #expect(family == nil)
  }

  @Test func parseTcpIpv6AddressWithFamily() throws {
    let address = try DBusAddress.parse("tcp:host=[::1],port=7777,family=ipv6")
    guard case .tcp(let host, let port, let family) = address else {
      #expect(Bool(false), "Expected tcp address")
      return
    }
    #expect(host == "::1")
    #expect(port == 7777)
    #expect(family == .ipv6)
  }

  @Test func parseNonceTcpAddress() throws {
    let address = try DBusAddress.parse("nonce-tcp:host=127.0.0.1,port=1234,noncefile=/tmp/nonce")
    guard case .nonceTcp(let host, let port, let family, let nonceFile) = address else {
      #expect(Bool(false), "Expected nonce-tcp address")
      return
    }
    #expect(host == "127.0.0.1")
    #expect(port == 1234)
    #expect(family == nil)
    #expect(nonceFile == "/tmp/nonce")
  }

  @Test func parseNonceTcpMissingNoncefileFails() {
    do {
      _ = try DBusAddress.parse("nonce-tcp:host=127.0.0.1,port=1234")
      #expect(Bool(false), "Expected missingKey error")
    } catch DBusAddressError.missingKey(let key) {
      #expect(key == "noncefile")
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }

  @Test func parseEmptyAddressFails() {
    do {
      _ = try DBusAddress.parse("")
      #expect(Bool(false), "Expected emptyAddress error")
    } catch DBusAddressError.emptyAddress {
      // Expected.
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }
}
