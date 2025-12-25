import Crypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#elseif canImport(Foundation)
  import Foundation
#endif

#if canImport(Glibc)
  import Glibc
#endif

internal enum DBusAuthMechanism: Equatable {
  case external(userID: String)
  case anonymous
  case cookieSha1(userName: String, homeDirectory: String)
  case cookieSha256(userName: String, homeDirectory: String)

  static func preferred(for auth: AuthType) -> [DBusAuthMechanism] {
    var mechanisms: [DBusAuthMechanism] = []
    switch auth.backing {
    case .external(let userID):
      mechanisms.append(.external(userID: userID))
      if let cookieInfo = DBusAuthUser.cookieInfo(userID: userID) {
        mechanisms.append(
          .cookieSha256(userName: cookieInfo.userName, homeDirectory: cookieInfo.homeDirectory))
        mechanisms.append(
          .cookieSha1(userName: cookieInfo.userName, homeDirectory: cookieInfo.homeDirectory))
      }
    case .anonymous:
      mechanisms.append(.anonymous)
      if let cookieInfo = DBusAuthUser.cookieInfo(userID: nil) {
        mechanisms.append(
          .cookieSha256(userName: cookieInfo.userName, homeDirectory: cookieInfo.homeDirectory))
        mechanisms.append(
          .cookieSha1(userName: cookieInfo.userName, homeDirectory: cookieInfo.homeDirectory))
      }
    }
    return mechanisms
  }

  var name: String {
    switch self {
    case .external:
      return "EXTERNAL"
    case .anonymous:
      return "ANONYMOUS"
    case .cookieSha1:
      return "DBUS_COOKIE_SHA1"
    case .cookieSha256:
      return "DBUS_COOKIE_SHA256"
    }
  }

  func authLine() throws -> String {
    switch self {
    case .external(let userID):
      let hex = DBusAuthEncoding.hexEncode(Array(userID.utf8))
      return "AUTH EXTERNAL \(hex)\r\n"
    case .anonymous:
      return "AUTH ANONYMOUS\r\n"
    case .cookieSha1(let userName, _), .cookieSha256(let userName, _):
      let hex = DBusAuthEncoding.hexEncode(Array(userName.utf8))
      return "AUTH \(name) \(hex)\r\n"
    }
  }

  func cookieResponse(for dataHex: String) throws -> String {
    switch self {
    case .cookieSha1(let userName, let homeDirectory):
      let response = try DBusAuthCookie.response(
        dataHex: dataHex,
        userName: userName,
        homeDirectory: homeDirectory,
        hash: .sha1
      )
      return "DATA \(response)\r\n"
    case .cookieSha256(let userName, let homeDirectory):
      let response = try DBusAuthCookie.response(
        dataHex: dataHex,
        userName: userName,
        homeDirectory: homeDirectory,
        hash: .sha256
      )
      return "DATA \(response)\r\n"
    default:
      throw DBusAuthenticationError.invalidAuthCommand
    }
  }
}

internal enum DBusAuthHash {
  case sha1
  case sha256
}

internal enum DBusAuthEncoding {
  static func hexEncode(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func hexEncode(_ string: String) -> String {
    hexEncode(Array(string.utf8))
  }

  static func hexDecode(_ hex: String) throws -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex)
      guard let next else { throw DBusAuthenticationError.invalidAuthCommand }
      let chunk = hex[index..<next]
      guard let byte = UInt8(chunk, radix: 16) else {
        throw DBusAuthenticationError.invalidAuthCommand
      }
      bytes.append(byte)
      index = next
    }
    return bytes
  }

  static func decodeHexString(_ hex: String) throws -> String {
    let bytes = try hexDecode(hex)
    return String(decoding: bytes, as: UTF8.self)
  }
}

internal enum DBusAuthCookie {
  static func response(
    dataHex: String,
    userName: String,
    homeDirectory: String,
    hash: DBusAuthHash
  ) throws -> String {
    let decoded = try DBusAuthEncoding.decodeHexString(dataHex)
    let parts = decoded.split(whereSeparator: {
      $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
    })
    guard parts.count == 3 else {
      throw DBusAuthenticationError.invalidAuthCommand
    }
    let context = String(parts[0])
    let cookieId = String(parts[1])
    let serverChallenge = String(parts[2])

    let cookie = try readCookie(context: context, id: cookieId, homeDirectory: homeDirectory)
    let clientChallenge = DBusAuthEncoding.hexEncode(randomBytes(count: 16))

    let digestInput = "\(serverChallenge):\(clientChallenge):\(cookie)"
    let digest = hashHexDigest(input: digestInput, hash: hash)
    let response = "\(clientChallenge) \(digest)"
    return DBusAuthEncoding.hexEncode(response)
  }

  private static func readCookie(
    context: String,
    id: String,
    homeDirectory: String
  ) throws -> String {
    let keyringURL = URL(fileURLWithPath: homeDirectory)
      .appendingPathComponent(".dbus-keyrings")
      .appendingPathComponent(context)
    let contents = try String(contentsOf: keyringURL, encoding: .utf8)
    for line in contents.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 3 else { continue }
      if fields[0] == id {
        return String(fields[2])
      }
    }
    throw DBusAuthenticationError.invalidAuthCommand
  }

  private static func hashHexDigest(input: String, hash: DBusAuthHash) -> String {
    let bytes = Array(input.utf8)
    switch hash {
    case .sha1:
      let digest = Insecure.SHA1.hash(data: bytes)
      return digest.map { String(format: "%02x", $0) }.joined()
    case .sha256:
      let digest = SHA256.hash(data: bytes)
      return digest.map { String(format: "%02x", $0) }.joined()
    }
  }

  private static func randomBytes(count: Int) -> [UInt8] {
    var bytes = [UInt8]()
    bytes.reserveCapacity(count)
    for _ in 0..<count {
      bytes.append(UInt8.random(in: UInt8.min...UInt8.max))
    }
    return bytes
  }
}

private enum DBusAuthUser {
  struct CookieInfo {
    let userName: String
    let homeDirectory: String
  }

  static func cookieInfo(userID: String?) -> CookieInfo? {
    guard let userName = resolveUserName(userID: userID) else { return nil }
    guard let homeDirectory = resolveHomeDirectory(userName: userName, userID: userID) else {
      return nil
    }
    return CookieInfo(userName: userName, homeDirectory: homeDirectory)
  }

  private static func resolveUserName(userID: String?) -> String? {
    #if canImport(Glibc)
      if let userID, let uid = UInt32(userID) {
        if let entry = getpwuid(uid_t(uid)) {
          return String(cString: entry.pointee.pw_name)
        }
      }
    #endif

    if let userID, !userID.isEmpty {
      return userID
    }

    if let env = ProcessInfo.processInfo.environment["USER"], !env.isEmpty {
      return env
    }

    #if canImport(Glibc)
      let uid = getuid()
      if let entry = getpwuid(uid) {
        return String(cString: entry.pointee.pw_name)
      }
    #endif

    return nil
  }

  private static func resolveHomeDirectory(userName: String, userID: String?) -> String? {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
      return home
    }

    #if canImport(Glibc)
      if let entry = getpwnam(userName) {
        return String(cString: entry.pointee.pw_dir)
      }
      if let userID, let uid = UInt32(userID), let entry = getpwuid(uid_t(uid)) {
        return String(cString: entry.pointee.pw_dir)
      }
    #endif

    return FileManager.default.homeDirectoryForCurrentUser.path
  }
}
