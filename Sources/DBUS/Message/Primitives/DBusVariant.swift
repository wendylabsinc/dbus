import NIOCore

/// A container type that can hold a value of any D-Bus type.
///
/// The D-Bus variant type is a container type that holds exactly one value of any other type.
/// When marshalled, a variant includes the signature of its contained value.
///
/// Variants are useful when the exact type of a value cannot be determined at compile time,
/// or when implementing generic interfaces that can accept different types of data.
///
/// - Note: According to the D-Bus specification, a variant has an alignment of 1 byte,
///   but the contained value still follows its own alignment rules.
///
/// - SeeAlso: [D-Bus Type System - Variant Type](https://dbus.freedesktop.org/doc/dbus-specification.html#type-system)
public struct DBusVariant: Sendable, Hashable {
  /// The D-Bus type signature of the contained value
  public let signature: String

  /// The actual value stored in the variant
  public let value: DBusValue

  internal init(typeSignature: String, value: DBusValue) {
    self.signature = typeSignature
    self.value = value
  }

  /// Creates a variant with an explicit type signature.
  ///
  /// This initializer is useful when you need to send an empty container value but
  /// still preserve the intended element signature (for example an empty array of
  /// strings should use the `as` signature instead of defaulting to `ay`).
  ///
  /// - Parameters:
  ///   - signature: The D-Bus type signature that should be advertised for the wrapped value.
  ///   - value: The value to wrap in the variant.
  public init(signature: String, value: DBusValue) {
    self.signature = signature
    self.value = value
  }

  /// Creates a variant containing the given D-Bus value.
  ///
  /// The signature is automatically derived from the value's type.
  ///
  /// - Parameter value: The D-Bus value to wrap in this variant
  public init(_ value: DBusValue) {
    self.signature = value.dbusTypeSignature
    self.value = value
  }

  /// Parses a D-Bus variant from a byte buffer.
  ///
  /// - Parameters:
  ///   - buffer: The byte buffer containing the marshalled variant
  ///   - byteOrder: The endianness used in the marshalled data
  ///
  /// - Throws: If the marshalled data cannot be parsed correctly
  init(from buffer: inout ByteBuffer, byteOrder: Endianness) throws {
    // Read the signature
    guard buffer.readableBytes >= 1 else {
      throw DBusError.invalidSignature
    }

    self.signature = try DBusString.readSignature(from: &buffer, byteOrder: byteOrder)

    // Ensure we have data left for the value
    guard buffer.readableBytes > 0 else {
      throw DBusError.invalidHeader
    }

    // Parse the value using the signature
    do {
      self.value = try DBusValue.parse(
        from: &buffer, typeSignature: signature, byteOrder: byteOrder)
    } catch {
      throw error
    }
  }
}

extension DBusVariant {
  /// Writes the variant to a byte buffer.
  ///
  /// The variant is marshalled according to the D-Bus specification:
  /// 1. The signature of the contained value as a SIGNATURE type
  /// 2. The marshalled value itself
  ///
  /// - Parameters:
  ///   - buffer: The byte buffer to write to
  ///   - byteOrder: The endianness to use for marshalling
  ///
  /// - SeeAlso: [D-Bus Marshalling - Variant Type](https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-marshaling-variant)
  func write(to buffer: inout ByteBuffer, byteOrder: Endianness) {
    // Write the signature
    buffer.writeInteger(UInt8(signature.utf8.count))
    buffer.writeBytes(Array(signature.utf8))
    buffer.writeInteger(UInt8(0))

    // Write the actual value
    value.write(to: &buffer, byteOrder: byteOrder)
  }
}
