import NIOCore

#if canImport(FoundationEssentials)
  import FoundationEssentials
#elseif canImport(Foundation)
  import Foundation
#endif

public enum DBusAddressError: Error, Equatable {
  case emptyAddress
  case noSupportedAddress
  case invalidEntry(String)
  case missingKey(String)
  case invalidPercentEncoding
  case invalidPort
  case invalidFamily
  case invalidNonceFile
  case missingSessionBusAddress
}

/// A parsed D-Bus address entry.
public enum DBusAddress: Sendable, Equatable {
  /// Address families supported by D-Bus TCP addresses.
  public enum Family: String, Sendable, Equatable {
    case ipv4
    case ipv6
  }

  /// `unix:path=/path/to/socket`
  case unix(path: String)
  /// `unix:abstract=name` (Linux only)
  case unixAbstract(name: String)
  /// `tcp:host=host,port=1234[,family=ipv4|ipv6]`
  case tcp(host: String, port: Int, family: Family?)
  /// `nonce-tcp:host=host,port=1234,noncefile=/path[,family=ipv4|ipv6]`
  case nonceTcp(host: String, port: Int, family: Family?, nonceFile: String)

  public static func parse(_ address: String) throws -> DBusAddress {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw DBusAddressError.emptyAddress
    }

    var lastError: DBusAddressError?
    for entry in trimmed.split(separator: ";") {
      do {
        if let parsed = try parseEntry(entry) {
          return parsed
        }
      } catch let error as DBusAddressError {
        lastError = error
      }
    }

    if let lastError {
      throw lastError
    }
    throw DBusAddressError.noSupportedAddress
  }

  public static func sessionBusAddress() throws -> DBusAddress {
    if let address = ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"],
      !address.isEmpty
    {
      return try parse(address)
    }
    if let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !runtime.isEmpty {
      return .unix(path: "\(runtime)/bus")
    }
    throw DBusAddressError.missingSessionBusAddress
  }

  public static func systemBusAddress() throws -> DBusAddress {
    if let address = ProcessInfo.processInfo.environment["DBUS_SYSTEM_BUS_ADDRESS"],
      !address.isEmpty
    {
      return try parse(address)
    }
    return .unix(path: "/var/run/dbus/system_bus_socket")
  }

  internal func unixSocketAddress() throws -> SocketAddress {
    switch self {
    case .unix(let path):
      return try SocketAddress(unixDomainSocketPath: path)
    case .unixAbstract(let name):
      #if canImport(Glibc)
        return try SocketAddress(unixDomainSocketPath: "\0" + name)
      #else
        throw DBusAddressError.invalidEntry("unix abstract addresses are not supported")
      #endif
    case .tcp, .nonceTcp:
      throw DBusAddressError.invalidEntry("expected unix address")
    }
  }

  private static func parseEntry(_ entry: Substring) throws -> DBusAddress? {
    let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let parts = trimmed.split(separator: ":", maxSplits: 1)
    let transport = String(parts[0])
    let params = parts.count > 1 ? String(parts[1]) : ""
    let values = try parseKeyValues(params)

    switch transport {
    case "unix":
      if let path = values["path"] {
        return .unix(path: path)
      }
      if let abstract = values["abstract"] {
        #if canImport(Glibc)
          return .unixAbstract(name: abstract)
        #else
          throw DBusAddressError.invalidEntry(String(entry))
        #endif
      }
      throw DBusAddressError.missingKey("path|abstract")
    case "tcp":
      return try parseTcp(values: values, entry: entry, nonceFile: nil)
    case "nonce-tcp":
      guard let nonceFile = values["noncefile"], !nonceFile.isEmpty else {
        throw DBusAddressError.missingKey("noncefile")
      }
      return try parseTcp(values: values, entry: entry, nonceFile: nonceFile)
    default:
      return nil
    }
  }

  private static func parseTcp(
    values: [String: String],
    entry: Substring,
    nonceFile: String?
  ) throws -> DBusAddress {
    guard let host = values["host"], !host.isEmpty else {
      throw DBusAddressError.missingKey("host")
    }
    guard let portText = values["port"], let port = Int(portText) else {
      throw DBusAddressError.invalidPort
    }
    guard (0...65535).contains(port) else {
      throw DBusAddressError.invalidPort
    }

    let normalizedHost = normalizeHost(host)
    let family = try parseFamily(values["family"])
    try validateFamilyForLiteral(host: normalizedHost, port: port, family: family)

    if let nonceFile {
      return .nonceTcp(host: normalizedHost, port: port, family: family, nonceFile: nonceFile)
    }
    return .tcp(host: normalizedHost, port: port, family: family)
  }

  private static func parseFamily(_ value: String?) throws -> Family? {
    guard let value, !value.isEmpty else { return nil }
    switch value.lowercased() {
    case "ipv4":
      return .ipv4
    case "ipv6":
      return .ipv6
    default:
      throw DBusAddressError.invalidFamily
    }
  }

  private static func validateFamilyForLiteral(
    host: String,
    port: Int,
    family: Family?
  ) throws {
    guard let family else { return }
    guard let socketAddress = try? SocketAddress(ipAddress: host, port: port) else {
      return
    }
    switch (family, socketAddress.protocol) {
    case (.ipv4, .inet), (.ipv6, .inet6):
      return
    default:
      throw DBusAddressError.invalidFamily
    }
  }

  private static func normalizeHost(_ host: String) -> String {
    if host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 {
      return String(host.dropFirst().dropLast())
    }
    return host
  }

  private static func parseKeyValues(_ params: String) throws -> [String: String] {
    guard !params.isEmpty else { return [:] }
    var result: [String: String] = [:]
    for pair in params.split(separator: ",") {
      guard let eq = pair.firstIndex(of: "=") else {
        throw DBusAddressError.invalidEntry(String(pair))
      }
      let key = String(pair[..<eq])
      let value = String(pair[pair.index(after: eq)...])
      result[key] = try decodePercentEscapes(value)
    }
    return result
  }

  private static func decodePercentEscapes(_ value: String) throws -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(value.utf8.count)
    var index = value.startIndex
    while index < value.endIndex {
      let char = value[index]
      if char == "%" {
        let first = value.index(after: index)
        let second = value.index(first, offsetBy: 1, limitedBy: value.endIndex)
        guard let second else {
          throw DBusAddressError.invalidPercentEncoding
        }
        let hex = value[first...second]
        guard let byte = UInt8(hex, radix: 16) else {
          throw DBusAddressError.invalidPercentEncoding
        }
        bytes.append(byte)
        index = value.index(after: second)
      } else {
        bytes.append(contentsOf: String(char).utf8)
        index = value.index(after: index)
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
