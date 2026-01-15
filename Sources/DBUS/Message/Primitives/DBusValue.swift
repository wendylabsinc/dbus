import NIOCore

/// A representation of all possible D-Bus data types.
///
/// D-Bus has a well-defined type system that includes basic types (integers, strings, etc.)
/// and container types (arrays, structs, dictionaries, variants). This enum provides Swift
/// representations of all these types and handles marshaling/unmarshaling to the D-Bus wire format.
///
/// Basic types directly map to Swift primitive types, while container types use Swift collections
/// to represent their D-Bus counterparts.
///
/// - SeeAlso: [D-Bus Type System](https://dbus.freedesktop.org/doc/dbus-specification.html#type-system)
/// - SeeAlso: [D-Bus Message Protocol - Marshaling](https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-marshaling)
public indirect enum DBusValue: Hashable, Sendable {
  /// A single byte (8 bits). D-Bus type code: 'y'.
  case byte(UInt8)

  /// A boolean value. D-Bus type code: 'b'.
  case boolean(Bool)

  /// A 16-bit signed integer. D-Bus type code: 'n'.
  case int16(Int16)

  /// A 16-bit unsigned integer. D-Bus type code: 'q'.
  case uint16(UInt16)

  /// A 32-bit signed integer. D-Bus type code: 'i'.
  case int32(Int32)

  /// A 32-bit unsigned integer. D-Bus type code: 'u'.
  case uint32(UInt32)

  /// A 64-bit signed integer. D-Bus type code: 'x'.
  case int64(Int64)

  /// A 64-bit unsigned integer. D-Bus type code: 't'.
  case uint64(UInt64)

  /// An IEEE 754 double-precision floating point number. D-Bus type code: 'd'.
  case double(Double)

  /// A UTF-8 encoded string. D-Bus type code: 's'.
  case string(String)

  /// A string following the D-Bus object path format rules. D-Bus type code: 'o'.
  case objectPath(String)

  /// A string following the D-Bus type signature format rules. D-Bus type code: 'g'.
  case signature(String)

  /// A 32-bit unsigned integer representing a file descriptor. D-Bus type code: 'h'.
  case unixFd(UInt32)

  /// A container type that can hold a value of any D-Bus type. D-Bus type code: 'v'.
  case variant(DBusVariant)

  /// An array of values all of the same type. D-Bus type code: 'a'.
  case array([DBusValue])

  /// A container of values of potentially different types. D-Bus type code: '(...)'.
  case structure([DBusValue])

  /// An associative array mapping keys to values. D-Bus type code: 'a{...}'.
  case dictionary([DBusValue: DBusValue])

  /// Returns the required byte alignment for a D-Bus type.
  ///
  /// D-Bus requires values to be aligned to specific byte boundaries based on their type.
  /// This method returns the alignment requirement in bytes for a given type signature.
  ///
  /// - Parameter typeSignature: The D-Bus type signature string.
  /// - Returns: The alignment requirement in bytes.
  /// - SeeAlso: [D-Bus Message Protocol - Alignment](https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-marshaling-alignment)
  static func alignment(for typeSignature: String) -> Int {
    guard let c = typeSignature.first else { return 1 }
    switch c {
    case "y": return 1  // BYTE
    case "n", "q": return 2  // INT16, UINT16
    // BOOLEAN, INT32, UINT32, STRING, OBJECT_PATH, SIGNATURE, UNIX_FD
    case "b", "i", "u", "s", "o", "g", "h": return 4
    case "x", "t", "d": return 8  // INT64, UINT64, DOUBLE
    case "a":
      return 4  // ARRAY (element alignment handled separately)
    case "(": return 8  // STRUCT
    case "{": return 8  // DICT_ENTRY
    case "v": return 1  // VARIANT (signature is 1, value is aligned as per type)
    default: return 1
    }
  }

  /// Parses a D-Bus value from a ByteBuffer based on the provided type signature.
  ///
  /// This method reads data from the buffer according to the D-Bus marshaling rules,
  /// ensuring proper alignment and byte order conversions.
  ///
  /// - Parameters:
  ///   - buffer: The buffer to read from. The buffer's reader index will be advanced.
  ///   - typeSignature: The D-Bus type signature for the value to parse.
  ///   - byteOrder: The byte order (endianness) of the data.
  /// - Returns: The parsed D-Bus value.
  /// - Throws: `DBusError` if the data cannot be parsed according to the type signature.
  static func parse(from buffer: inout ByteBuffer, typeSignature: String, byteOrder: Endianness)
    throws -> DBusValue
  {
    guard let typeChar = typeSignature.first else {
      throw DBusError.invalidSignature
    }
    // Align buffer before reading value
    let alignment = alignment(for: typeSignature)
    buffer.alignReader(to: alignment)
    switch typeChar {
    case "y": return .byte(try buffer.requireInteger(endianness: byteOrder))
    case "b":
      // Boolean is a 32-bit integer with value 0 or 1, align to 4 bytes
      buffer.alignReader(to: 4)
      return .boolean(try buffer.requireInteger(endianness: byteOrder) as UInt32 != 0)
    case "n": return .int16(try buffer.requireInteger(endianness: byteOrder))
    case "q": return .uint16(try buffer.requireInteger(endianness: byteOrder))
    case "i": return .int32(try buffer.requireInteger(endianness: byteOrder))
    case "u": return .uint32(try buffer.requireInteger(endianness: byteOrder))
    case "x": return .int64(try buffer.requireInteger(endianness: byteOrder))
    case "t": return .uint64(try buffer.requireInteger(endianness: byteOrder))
    case "d": return .double(try buffer.requireDouble(endianness: byteOrder))
    case "s": return .string(try DBusString.read(from: &buffer, byteOrder: byteOrder))
    case "o": return .objectPath(try DBusString.read(from: &buffer, byteOrder: byteOrder))
    case "g": return .signature(try DBusString.readSignature(from: &buffer, byteOrder: byteOrder))
    case "h": return .unixFd(try buffer.requireInteger(endianness: byteOrder))
    case "v": return .variant(try DBusVariant(from: &buffer, byteOrder: byteOrder))
    case "a":
      let elementSig = String(typeSignature.dropFirst())
      let arrayLen = try buffer.requireInteger(endianness: byteOrder) as UInt32

      // If array length is 0, there's no need to align further
      if arrayLen == 0 {
        if elementSig.starts(with: "{") {
          // Create empty dictionary with the correct type signature
          return .dictionary([:])
        } else {
          // Create empty array with the correct type signature
          // Store the element type so we can preserve it
          return .array([])
        }
      }

      // Align the buffer to the element's alignment
      buffer.alignReader(to: Self.alignment(for: elementSig))

      // Track the maximum bytes we should read from the array
      let maxArrayBytes = Int(arrayLen)
      let arrayEndPosition = buffer.readerIndex + maxArrayBytes
      if arrayEndPosition > buffer.writerIndex {
        throw DBusError.invalidHeader
      }

      func alignWithinArray(_ alignment: Int) throws {
        let misalignment = buffer.readerIndex % alignment
        if misalignment == 0 {
          return
        }
        let padding = alignment - misalignment
        let newIndex = buffer.readerIndex + padding
        if newIndex > arrayEndPosition {
          throw DBusError.invalidHeader
        }
        buffer.moveReaderIndex(forwardBy: padding)
      }

      if elementSig.starts(with: "{") {
        // Parse the dictionary entry signatures
        let inner = String(elementSig.dropFirst().dropLast())

        // The dictionary key and value types
        var keyType = ""
        var valueType = ""

        // Try to parse the key and value types correctly
        var remainingSignature = inner
        if !remainingSignature.isEmpty {
          keyType = try parseNextTypeSignature(from: &remainingSignature)
          if !remainingSignature.isEmpty {
            valueType = remainingSignature
          }
        }

        if keyType.isEmpty || valueType.isEmpty {
          throw DBusError.invalidSignature
        }

        var dict: [DBusValue: DBusValue] = [:]

        // Read dictionary entries until we reach the array end
        while buffer.readerIndex < arrayEndPosition {
          try alignWithinArray(8)  // Dict entries are aligned to 8 bytes

          // Ensure we don't read past the array end
          if buffer.readerIndex >= arrayEndPosition {
            break
          }

          let key = try DBusValue.parse(from: &buffer, typeSignature: keyType, byteOrder: byteOrder)
          let value = try DBusValue.parse(
            from: &buffer, typeSignature: valueType, byteOrder: byteOrder)
          dict[key] = value
        }

        // Ensure we've read exactly the array length
        if buffer.readerIndex > arrayEndPosition {
          throw DBusError.invalidHeader
        }

        // Skip any remaining bytes in the array (shouldn't happen if parsing is correct)
        if buffer.readerIndex < arrayEndPosition {
          let remaining = arrayEndPosition - buffer.readerIndex
          buffer.moveReaderIndex(forwardBy: remaining)
        }

        return .dictionary(dict)
      } else {
        var elements: [DBusValue] = []

        // Read array elements until we reach the array end
        while buffer.readerIndex < arrayEndPosition {
          // Ensure we don't read past the array end
          if buffer.readerIndex >= arrayEndPosition {
            break
          }

          try alignWithinArray(Self.alignment(for: elementSig))
          elements.append(
            try DBusValue.parse(from: &buffer, typeSignature: elementSig, byteOrder: byteOrder))
        }

        // Ensure we've read exactly the array length
        if buffer.readerIndex > arrayEndPosition {
          throw DBusError.invalidHeader
        }

        // Skip any remaining bytes in the array (shouldn't happen if parsing is correct)
        if buffer.readerIndex < arrayEndPosition {
          let remaining = arrayEndPosition - buffer.readerIndex
          buffer.moveReaderIndex(forwardBy: remaining)
        }

        return .array(elements)
      }
    case "(":
      // Handle struct parsing more carefully
      let inner = String(typeSignature.dropFirst().dropLast())
      var fields: [DBusValue] = []

      // Parse each type signature in the struct
      var remaining = inner
      while !remaining.isEmpty {
        let fieldSig = try parseNextTypeSignature(from: &remaining)
        fields.append(
          try DBusValue.parse(from: &buffer, typeSignature: fieldSig, byteOrder: byteOrder))
      }

      return .structure(fields)
    default:
      throw DBusError.unsupportedType
    }
  }

  /// Helper method to parse the next complete type signature from a compound signature
  internal static func parseNextTypeSignature(from signature: inout String) throws -> String {
    guard !signature.isEmpty else {
      throw DBusError.invalidSignature
    }

    let firstChar = signature.first!

    // For simple types, just consume one character
    if "ybnqiuxtdsogvh".contains(firstChar) {
      signature.removeFirst()
      return String(firstChar)
    }

    // For variant type
    if firstChar == "v" {
      signature.removeFirst()
      return "v"
    }

    // For array types
    if firstChar == "a" {
      signature.removeFirst()

      // Handle dictionary types specially
      if !signature.isEmpty && signature.first == "{" {
        var depth = 0
        var dictSig = "{"
        signature.removeFirst()  // Remove the '{'
        depth += 1

        // Collect all characters until the matching '}'
        while !signature.isEmpty && depth > 0 {
          let c = signature.removeFirst()
          dictSig.append(c)

          if c == "{" {
            depth += 1
          } else if c == "}" {
            depth -= 1
          }
        }

        return "a" + dictSig
      }

      // For regular arrays, recursively get the element type
      if !signature.isEmpty {
        let elementType = try parseNextTypeSignature(from: &signature)
        return "a" + elementType
      } else {
        throw DBusError.invalidSignature
      }
    }

    // For struct types
    if firstChar == "(" {
      var depth = 0
      var structSig = "("
      signature.removeFirst()  // Remove the '('
      depth += 1

      // Collect all characters until the matching ')'
      while !signature.isEmpty && depth > 0 {
        let c = signature.removeFirst()
        structSig.append(c)

        if c == "(" {
          depth += 1
        } else if c == ")" {
          depth -= 1
        }
      }

      return structSig
    }

    // Shouldn't get here with valid signatures
    throw DBusError.invalidSignature
  }

  private static func typeToString(_ type: DBusType) -> String {
    switch type {
    case .byte: return "y"
    case .boolean: return "b"
    case .int16: return "n"
    case .uint16: return "q"
    case .int32: return "i"
    case .uint32: return "u"
    case .int64: return "x"
    case .uint64: return "t"
    case .double: return "d"
    case .string: return "s"
    case .objectPath: return "o"
    case .signature: return "g"
    case .unixFd: return "h"
    case .variant: return "v"
    case .array(let elemType):
      return "a" + typeToString(elemType)
    case .structure(let types):
      return "(" + types.map(typeToString).joined() + ")"
    case .dictEntry(let key, let value):
      return "{" + typeToString(key) + typeToString(value) + "}"
    }
  }
}

extension DBusValue {
  /// Returns the byte value if this value is a byte or a variant containing a byte.
  ///
  /// - Returns: The byte value if this value is a byte or a variant containing a byte, otherwise `nil`.
  public var byte: UInt8? {
    switch self {
    case .byte(let value):
      return value
    case .variant(let variant):
      guard case .byte(let value) = variant.value else { return nil }
      return value
    default:
      return nil
    }
  }

  /// Returns the uint8 value if this value is a uint8 or a variant containing a uint8.
  ///
  /// - Returns: The uint8 value if this value is a uint8 or a variant containing a uint8, otherwise `nil`.
  public var uint8: UInt8? { byte }

  /// Returns the boolean value if this value is a boolean or a variant containing a boolean.
  ///
  /// - Returns: The boolean value if this value is a boolean or a variant containing a boolean, otherwise `nil`.
  public var boolean: Bool? {
    switch self {
    case .boolean(let value):
      return value
    case .variant(let variant):
      guard case .boolean(let value) = variant.value else { return nil }
      return value
    default:
      return nil
    }
  }

  /// Returns the int16 value if this value is an int16 or a variant containing an int16.
  ///
  /// - Returns: The int16 value if this value is an int16 or a variant containing an int16, otherwise `nil`.
  public var int16: Int16? {
    switch self {
    case .int16(let value):
      return value
    case .variant(let variant):
      guard case .int16(let value) = variant.value else { return nil }
      return value
    default:
      return nil
    }
  }

  /// Returns the uint16 value if this value is a uint16 or a variant containing a uint16.
  ///
  /// - Returns: The uint16 value if this value is a uint16 or a variant containing a uint16, otherwise `nil`.
  public var uint16: UInt16? {
    switch self {
    case .uint16(let value):
      return value
    case .variant(let variant):
      guard case .uint16(let value) = variant.value else { return nil }
      return value
    default:
      return nil
    }
  }

  /// Returns the int32 value if this value is an int32 or a variant containing an int32.
  ///
  /// - Returns: The int32 value if this value is an int32 or a variant containing an int32, otherwise `nil`.
  public var int32: Int32? {
    switch self {
    case .int32(let value):
      return value
    case .variant(let variant):
      guard case .int32(let value) = variant.value else { return nil }
      return value
    default:
      return nil
    }
  }

  /// Returns the int64 value if this value is an int64 or a variant containing an int64.
  ///
  /// - Returns: The int64 value if this value is an int64 or a variant containing an int64, otherwise `nil`.
  public var int64: Int64? {
    switch self {
    case .int64(let value):
      return value
    case .variant(let variant):
      guard case .int64(let value) = variant.value else { return nil }
      return value
    default:
      return nil
    }
  }

  /// Returns the uint64 value if this value is a uint64 or a variant containing a uint64.
  ///
  /// - Returns: The uint64 value if this value is a uint64 or a variant containing a uint64, otherwise `nil`.
  public var uint64: UInt64? {
    switch self {
    case .uint64(let value):
      return value
    case .variant(let variant):
      guard case .uint64(let value) = variant.value else { return nil }
      return value
    default:
      return nil
    }
  }

  /// Returns the double value if this value is a double or a variant containing a double.
  ///
  /// - Returns: The double value if this value is a double or a variant containing a double, otherwise `nil`.
  public var double: Double? {
    switch self {
    case .double(let value):
      return value
    case .variant(let variant):
      guard case .double(let value) = variant.value else { return nil }
      return value
    default:
      return nil
    }
  }

  /// Returns the string value if this value is a string or a variant containing a string.
  ///
  /// - Returns: The string value if this value is a string or a variant containing a string, otherwise `nil`.
  public var string: String? {
    switch self {
    case .string(let value):
      return value
    case .variant(let variant):
      guard case .string(let value) = variant.value else { return nil }
      return value
    default:
      return nil
    }
  }

  /// Returns the Unix file descriptor if this value is a Unix FD or a variant containing a Unix FD.
  ///
  /// - Returns: The Unix file descriptor if this value is a Unix FD or a variant containing a Unix FD, otherwise `nil`.
  public var unixFd: UInt32? {
    switch self {
    case .unixFd(let value):
      return value
    case .variant(let variant):
      guard case .unixFd(let value) = variant.value else { return nil }
      return value
    default:
      return nil
    }
  }

  /// Returns the array values if this value is an array or a variant containing an array.
  ///
  /// - Returns: The array values if this value is an array or a variant containing an array, otherwise `nil`.
  public var array: [DBusValue]? {
    switch self {
    case .array(let values):
      return values
    case .variant(let variant):
      guard case .array(let values) = variant.value else { return nil }
      return values
    default:
      return nil
    }
  }

  /// Returns the structure values if this value is a structure or a variant containing a structure.
  ///
  /// - Returns: The structure values if this value is a structure or a variant containing a structure, otherwise `nil`.
  public var structure: [DBusValue]? {
    switch self {
    case .structure(let values):
      return values
    case .variant(let variant):
      guard case .structure(let values) = variant.value else { return nil }
      return values
    default:
      return nil
    }
  }

  /// Returns the object path if this value is an object path or a variant containing an object path.
  ///
  /// - Returns: The object path if this value is an object path or a variant containing an object path, otherwise `nil`.
  public var objectPath: String? {
    switch self {
    case .objectPath(let path):
      return path
    case .variant(let variant):
      guard case .objectPath(let path) = variant.value else { return nil }
      return path
    default:
      return nil
    }
  }

  /// Returns the uint32 value if this value is a uint32 or a variant containing a uint32.
  ///
  /// - Returns: The uint32 value if this value is a uint32 or a variant containing a uint32, otherwise `nil`.
  public var uint32: UInt32? {
    switch self {
    case .uint32(let value):
      return value
    case .variant(let variant):
      guard case .uint32(let value) = variant.value else { return nil }
      return value
    default:
      return nil
    }
  }

  /// Writes this D-Bus value to a ByteBuffer according to the D-Bus marshaling rules.
  ///
  /// This method handles proper alignment and endianness conversion when writing values.
  ///
  /// - Parameters:
  ///   - buffer: The buffer to write to. The buffer's writer index will be advanced.
  ///   - byteOrder: The byte order (endianness) to use when writing multi-byte values.
  func write(to buffer: inout ByteBuffer, byteOrder: Endianness) {
    switch self {
    case .byte(let v):
      buffer.writeInteger(v)
    case .boolean(let v):
      buffer.alignWriter(to: 4)
      buffer.writeInteger(v ? UInt32(1) : UInt32(0), endianness: byteOrder)
    case .int16(let v):
      buffer.alignWriter(to: 2)
      buffer.writeInteger(v, endianness: byteOrder)
    case .uint16(let v):
      buffer.alignWriter(to: 2)
      buffer.writeInteger(v, endianness: byteOrder)
    case .int32(let v):
      buffer.alignWriter(to: 4)
      buffer.writeInteger(v, endianness: byteOrder)
    case .uint32(let v):
      buffer.alignWriter(to: 4)
      buffer.writeInteger(v, endianness: byteOrder)
    case .int64(let v):
      buffer.alignWriter(to: 8)
      buffer.writeInteger(v, endianness: byteOrder)
    case .uint64(let v):
      buffer.alignWriter(to: 8)
      buffer.writeInteger(v, endianness: byteOrder)
    case .double(let v):
      buffer.alignWriter(to: 8)
      buffer.writeInteger(v.bitPattern, endianness: byteOrder)
    case .string(let s):
      buffer.alignWriter(to: 4)
      let bytes = Array(s.utf8)
      buffer.writeInteger(UInt32(bytes.count), endianness: byteOrder)
      buffer.writeBytes(bytes)
      buffer.writeInteger(UInt8(0))
    case .objectPath(let s):
      buffer.alignWriter(to: 4)
      let bytes = Array(s.utf8)
      buffer.writeInteger(UInt32(bytes.count), endianness: byteOrder)
      buffer.writeBytes(bytes)
      buffer.writeInteger(UInt8(0))
    case .signature(let s):
      buffer.writeInteger(UInt8(s.utf8.count))
      buffer.writeBytes(Array(s.utf8))
      buffer.writeInteger(UInt8(0))
    case .unixFd(let v):
      buffer.alignWriter(to: 4)
      buffer.writeInteger(v, endianness: byteOrder)
    case .variant(let v):
      v.write(to: &buffer, byteOrder: byteOrder)
    case .array(let arr):
      buffer.alignWriter(to: 4)
      let start = buffer.writerIndex
      buffer.writeInteger(UInt32(0), endianness: byteOrder)  // Placeholder for length

      // Only align and write content if there are elements
      if !arr.isEmpty {
        let align = arr.first.map { DBusValue.alignment(for: $0.dbusTypeSignature) } ?? 1
        buffer.alignWriter(to: align)
        let arrayStart = buffer.writerIndex
        for el in arr {
          el.write(to: &buffer, byteOrder: byteOrder)
        }
        let arrayEnd = buffer.writerIndex
        let len = UInt32(arrayEnd - arrayStart)
        buffer.setInteger(len, at: start, endianness: byteOrder)
      }
    case .structure(let fields):
      buffer.alignWriter(to: 8)
      for f in fields {
        f.write(to: &buffer, byteOrder: byteOrder)
      }
    case .dictionary(let dict):
      buffer.alignWriter(to: 4)
      let start = buffer.writerIndex
      buffer.writeInteger(UInt32(0), endianness: byteOrder)  // Placeholder for length

      // D-Bus spec: even empty arrays must include alignment padding for element type
      // Dict entries have 8-byte alignment
      buffer.alignWriter(to: 8)

      if !dict.isEmpty {
        let dictStart = buffer.writerIndex
        for (k, v) in dict {
          buffer.alignWriter(to: 8)
          k.write(to: &buffer, byteOrder: byteOrder)
          v.write(to: &buffer, byteOrder: byteOrder)
        }
        let dictEnd = buffer.writerIndex
        let len = UInt32(dictEnd - dictStart)
        buffer.setInteger(len, at: start, endianness: byteOrder)
      }
    }
  }

  /// Returns the D-Bus type signature string for this value.
  ///
  /// Each D-Bus value has a corresponding type signature that describes its type.
  /// This computed property returns the signature string for the current value.
  ///
  /// - Returns: A string containing the D-Bus type signature.
  /// - SeeAlso: [D-Bus Type Signatures](https://dbus.freedesktop.org/doc/dbus-specification.html#type-system)
  var dbusTypeSignature: String {
    switch self {
    case .byte: return "y"
    case .boolean: return "b"
    case .int16: return "n"
    case .uint16: return "q"
    case .int32: return "i"
    case .uint32: return "u"
    case .int64: return "x"
    case .uint64: return "t"
    case .double: return "d"
    case .string: return "s"
    case .objectPath: return "o"
    case .signature: return "g"
    case .unixFd: return "h"
    case .variant: return "v"
    case .array(let arr):
      if let firstElement = arr.first {
        return "a" + firstElement.dbusTypeSignature
      } else {
        // Use the stored element type for empty arrays
        return "ay"
      }
    case .structure(let fields):
      return "(" + fields.map { $0.dbusTypeSignature }.joined() + ")"
    case .dictionary(let dict):
      if let (k, v) = dict.first {
        return "a{" + k.dbusTypeSignature + v.dbusTypeSignature + "}"
      } else {
        // Use standard string-variant dictionary for empty dictionaries
        return "a{sv}"
      }
    }
  }
}
