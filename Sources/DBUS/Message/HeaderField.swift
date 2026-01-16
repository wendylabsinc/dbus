import NIOCore

/// A header field in a D-Bus message.
///
/// Header fields contain metadata about D-Bus messages. Each field consists of a code identifying
/// the type of field and a variant containing the field's value. Different message types require
/// different header fields to be present.
///
/// ## Common Header Fields
///
/// - **Path**: The object path for method calls and signals
/// - **Interface**: The interface name (optional for method calls, required for signals)
/// - **Member**: The method or signal name
/// - **Destination**: The intended recipient of the message
/// - **Sender**: The unique name of the sending connection
/// - **ReplySerial**: Links replies to their original method calls
/// - **Signature**: Describes the types in the message body
///
/// ## Example
/// ```swift
/// // Creating header fields for a method call
/// let pathField = HeaderField(
///     code: .path,
///     variant: DBusVariant(.objectPath("/org/example/Object"))
/// )
/// let methodField = HeaderField(
///     code: .member,
///     variant: DBusVariant(.string("DoSomething"))
/// )
/// ```
public struct HeaderField: Sendable {
  /// The type of this header field.
  public let code: HeaderField.Code

  /// The value of this header field, wrapped in a variant.
  public let variant: DBusVariant

  init(code: HeaderField.Code, variant: DBusVariant) {
    self.code = code
    self.variant = variant
  }

  init(from buffer: inout ByteBuffer, byteOrder: Endianness) throws {
    buffer.alignReader(to: 8)
    guard
      let code: UInt8 = buffer.readInteger(),
      let code = HeaderField.Code(rawValue: code)
    else {
      throw DBusError.invalidHeaderField
    }

    let variant = try DBusVariant(from: &buffer, byteOrder: byteOrder)

    // Validate header field value
    switch code {
    case .path:
      guard
        case .objectPath(let s) = variant.value,
        HeaderField.isValidObjectPath(s)
      else {
        throw DBusError.invalidHeaderField
      }
    case .interface:
      guard
        case .string(let s) = variant.value,
        HeaderField.isValidInterfaceName(s)
      else {
        throw DBusError.invalidHeaderField
      }
    case .destination, .sender:
      guard
        case .string(let s) = variant.value
      else {
        throw DBusError.invalidHeaderField
      }

      guard HeaderField.isValidConnectionName(s) else {
        throw DBusError.invalidHeaderField
      }

    case .member:
      guard
        case .string(let s) = variant.value,
        HeaderField.isValidMemberName(s)
      else {
        throw DBusError.invalidHeaderField
      }
    case .errorName:
      guard
        case .string(let s) = variant.value,
        HeaderField.isValidErrorName(s)
      else {
        throw DBusError.invalidHeaderField
      }
    case .replySerial, .unixFds:
      // Should be uint32
      if case .uint32 = variant.value {
      } else {
        throw DBusError.invalidHeaderField
      }
    case .signature:
      guard
        case .signature(let sig) = variant.value,
        (try? DBusTypeSignature(sig)) != nil  // Throws if invalid
      else {
        throw DBusError.invalidHeaderField
      }
    }
    self.code = code
    self.variant = variant
  }

  // D-Bus object path: must start with '/', no empty segments, no trailing '/', only [A-Za-z0-9_]
  static func isValidObjectPath(_ s: String) -> Bool {
    guard s.first == "/" else { return false }
    if s == "/" { return true }
    if s.contains("//") { return false }
    if s.last == "/" { return false }
    for segment in s.split(separator: "/") where !segment.isEmpty {
      if !segment.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { return false }
    }
    return true
  }

  // D-Bus interface, destination, sender: dot-separated, each element [A-Za-z_][A-Za-z0-9_]*, at least 2 elements
  static func isValidInterfaceName(_ s: some StringProtocol) -> Bool {
    let parts = s.split(separator: ".")
    guard parts.count >= 2 else { return false }
    for part in parts {
      guard let first = part.first, first.isLetter || first == "_" else { return false }
      if !part.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { return false }
    }
    return true
  }

  // D-Bus member: [A-Za-z_][A-Za-z0-9_]*
  static func isValidConnectionName(_ s: some StringProtocol) -> Bool {
    if s.first == ":" {
      let parts = s.dropFirst().split(separator: ".")
      guard parts.count >= 2 else { return false }
      guard parts.allSatisfy({ !$0.isEmpty }) else { return false }
      return true
    } else {
      return isValidInterfaceName(s)
    }
  }

  // D-Bus member: [A-Za-z_][A-Za-z0-9_]*
  static func isValidMemberName(_ s: some StringProtocol) -> Bool {
    guard let first = s.first, first.isLetter || first == "_" else { return false }
    return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
  }

  // D-Bus error name: same as interface name
  static func isValidErrorName(_ s: some StringProtocol) -> Bool {
    return isValidInterfaceName(s)
  }
}

extension HeaderField {
  func write(to buffer: inout ByteBuffer, byteOrder: Endianness) {
    buffer.alignWriter(to: 8)
    buffer.writeInteger(code.rawValue)
    // Write variant
    variant.write(to: &buffer, byteOrder: byteOrder)
  }
}
