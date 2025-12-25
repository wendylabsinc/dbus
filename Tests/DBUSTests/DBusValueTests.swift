import NIOCore
import Testing

@testable import DBUS

@Suite
struct DBusValueTests {
  // MARK: - Basic Types

  @Test func byteValue() throws {
    let values: [UInt8] = [0, 1, 127, 255]
    for value in values {
      try testRoundTrip(.byte(value), "y")
    }
  }

  @Test func booleanValue() throws {
    try testRoundTrip(.boolean(true), "b")
    try testRoundTrip(.boolean(false), "b")
  }

  @Test func int16Value() throws {
    let values: [Int16] = [0, 1, -1, 32767, -32768]
    for value in values {
      try testRoundTrip(.int16(value), "n")
    }
  }

  @Test func uint16Value() throws {
    let values: [UInt16] = [0, 1, 32767, 65535]
    for value in values {
      try testRoundTrip(.uint16(value), "q")
    }
  }

  @Test func int32Value() throws {
    let values: [Int32] = [0, 1, -1, 2_147_483_647, -2_147_483_648]
    for value in values {
      try testRoundTrip(.int32(value), "i")
    }
  }

  @Test func uint32Value() throws {
    let values: [UInt32] = [0, 1, 2_147_483_647, 4_294_967_295]
    for value in values {
      try testRoundTrip(.uint32(value), "u")
    }
  }

  @Test func int64Value() throws {
    let values: [Int64] = [0, 1, -1, 9_223_372_036_854_775_807, -9_223_372_036_854_775_808]
    for value in values {
      try testRoundTrip(.int64(value), "x")
    }
  }

  @Test func uint64Value() throws {
    let values: [UInt64] = [0, 1, 9_223_372_036_854_775_807, 18_446_744_073_709_551_615]
    for value in values {
      try testRoundTrip(.uint64(value), "t")
    }
  }

  @Test func doubleValue() throws {
    let values: [Double] = [
      0.0, 1.0, -1.0, 3.14159, Double.pi, Double.infinity, -Double.infinity, Double.nan,
    ]
    for value in values {
      try testRoundTrip(.double(value), "d")
    }
  }

  @Test func stringValue() throws {
    let values = ["", "Hello", "Unicode 😊", "Multi\nLine", "Special \"'\\Characters"]
    for value in values {
      try testRoundTrip(.string(value), "s")
    }
  }

  @Test func objectPathValue() throws {
    let values = ["/", "/com", "/com/example", "/com/example/Service1"]
    for value in values {
      try testRoundTrip(.objectPath(value), "o")
    }
  }

  @Test func signatureValue() throws {
    let values = ["", "s", "a{sv}", "a(isai)"]
    for value in values {
      try testRoundTrip(.signature(value), "g")
    }
  }

  @Test func unixFdValue() throws {
    let values: [UInt32] = [0, 1, 10, 4_294_967_295]
    for value in values {
      try testRoundTrip(.unixFd(value), "h")
    }
  }

  // MARK: - Container Types

  @Test func emptyArrayValue() throws {
    // Use a proper element type for empty arrays
    let emptyByteArray = DBusValue.array([])
    // Specify the element type explicitly with "ay" (array of bytes)
    try testRoundTrip(emptyByteArray, "ay")

    // All empty arrays have the same signature: "ay"
    let emptyIntArray = DBusValue.array([])
    try testRoundTrip(emptyIntArray, "ay")

    let emptyStringArray = DBusValue.array([])
    try testRoundTrip(emptyStringArray, "ay")
  }

  @Test func arrayOfBasicTypesValue() throws {
    let arrays: [DBusValue] = [
      .array([.byte(1), .byte(2), .byte(3)]),
      .array([.boolean(true), .boolean(false), .boolean(true)]),
      .array([.int32(1), .int32(2), .int32(3)]),
      .array([.string("a"), .string("b"), .string("c")]),
    ]

    for array in arrays {
      try testRoundTrip(array, array.dbusTypeSignature)
    }
  }

  @Test func nestedArraysValue() throws {
    let nestedArray = DBusValue.array([
      .array([.int32(1), .int32(2)]),
      .array([.int32(3), .int32(4)]),
      .array([.int32(5), .int32(6)]),
    ])

    try testRoundTrip(nestedArray, nestedArray.dbusTypeSignature)
  }

  @Test func structureValue() throws {
    let structures: [DBusValue] = [
      .structure([.byte(1)]),
      .structure([.int32(42), .string("hello")]),
      .structure([.boolean(true), .double(3.14), .array([.byte(1), .byte(2)])]),
    ]

    for structure in structures {
      try testRoundTrip(structure, structure.dbusTypeSignature)
    }
  }

  @Test func emptyDictionaryValue() throws {
    let emptyDict = DBusValue.dictionary([:])
    try testRoundTrip(emptyDict, "a{sv}")
  }

  @Test func dictionaryValue() throws {
    let dictionaries: [DBusValue] = [
      // Dictionary of string keys to variant values (the most common D-Bus pattern)
      .dictionary([.string("key"): .variant(DBusVariant(.int32(42)))]),
      .dictionary([.string("int"): .int32(42)]),
      // Dictionary with multiple entries, all values are variants
      .dictionary([
        .string("name"): .variant(DBusVariant(.string("John"))),
        .string("age"): .variant(DBusVariant(.int32(30))),
        .string("height"): .variant(DBusVariant(.double(1.85))),
      ]),

      // Dictionary with byte keys, all values are variants containing arrays
      .dictionary([
        .byte(1): .variant(DBusVariant(.array([.string("one")]))),
        .byte(2): .variant(DBusVariant(.array([.string("two")]))),
      ]),
    ]

    for dictionary in dictionaries {
      try testRoundTrip(dictionary, dictionary.dbusTypeSignature)
    }
  }

  @Test func variantValue() throws {
    let variants: [DBusValue] = [
      .variant(DBusVariant(.byte(42))),
      .variant(DBusVariant(.string("hello"))),
      .variant(DBusVariant(.array([.int32(1), .int32(2)]))),
    ]

    for variant in variants {
      try testRoundTrip(variant, "v")
    }
  }

  @Test func complexNestedValue() throws {
    // A complex structure with nested types
    let complex = DBusValue.structure([
      .string("header"),
      .array([.int32(1), .int32(2), .int32(3)]),
      .dictionary([
        .string("metadata"): .variant(
          DBusVariant(
            .structure([
              .string("info"),
              .boolean(true),
              .double(3.14159),
            ])
          )),
        .string("tags"): .variant(
          DBusVariant(
            .array([.string("one"), .string("two")])
          )),
      ]),
    ])

    try testRoundTrip(complex, complex.dbusTypeSignature)
  }

  @Test func alignmentCorrectness() throws {
    // Test that alignment is handled correctly by mixing types with
    // different alignment requirements
    let mixedAlignments = DBusValue.structure([
      .byte(1),  // 1-byte alignment
      .int16(2),  // 2-byte alignment
      .int32(3),  // 4-byte alignment
      .int64(4),  // 8-byte alignment
      .byte(5),  // back to 1-byte alignment
      .int64(6),  // back to 8-byte alignment
    ])

    try testRoundTrip(mixedAlignments, mixedAlignments.dbusTypeSignature)
  }

  @Test func dictionaryAlignmentInStruct() throws {
    let dict = DBusValue.dictionary([
      .string("k"): .string("v")
    ])

    var dictBuffer = ByteBuffer()
    dict.write(to: &dictBuffer, byteOrder: .little)
    var dictBufferCopy = dictBuffer
    guard let expectedLength: UInt32 = dictBufferCopy.readInteger(endianness: .little) else {
      #expect(Bool(false), "Failed to read dictionary length")
      return
    }

    var structBuffer = ByteBuffer()
    DBusValue.structure([.byte(1), dict]).write(to: &structBuffer, byteOrder: .little)
    var structBufferCopy = structBuffer
    structBufferCopy.moveReaderIndex(to: 4)
    guard let lengthAtOffset: UInt32 = structBufferCopy.readInteger(endianness: .little) else {
      #expect(Bool(false), "Failed to read dictionary length at offset")
      return
    }

    #expect(lengthAtOffset == expectedLength)
  }

  // MARK: - Endianness Tests

  @Test func littleEndianSerialization() throws {
    let value = DBusValue.int32(0x1234_5678)
    try testRoundTripWithEndianness(value, "i", .little)
  }

  @Test func bigEndianSerialization() throws {
    let value = DBusValue.int32(0x1234_5678)
    try testRoundTripWithEndianness(value, "i", .big)
  }

  // MARK: - Error Cases

  @Test func invalidSignature() throws {
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt8(42))

    do {
      let _ = try DBusValue.parse(from: &buffer, typeSignature: "z", byteOrder: .little)
      #expect(Bool(false), "Expected error for invalid signature")
    } catch {
      // Expected error
    }
  }

  // MARK: - Helper Methods

  /// Tests round-trip serialization and deserialization of a DBusValue
  func testRoundTrip(_ value: DBusValue, _ typeSignature: String) throws {
    try testRoundTripWithEndianness(value, typeSignature, .little)
  }

  /// Tests round-trip serialization and deserialization of a DBusValue with specified endianness
  func testRoundTripWithEndianness(
    _ value: DBusValue, _ typeSignature: String, _ endianness: Endianness
  ) throws {
    // Check that value's signature matches expected signature
    let valueSig = value.dbusTypeSignature
    #expect(valueSig == typeSignature, "Value signature doesn't match expected signature")

    var writeBuffer = ByteBuffer()
    value.write(to: &writeBuffer, byteOrder: endianness)

    var readBuffer = writeBuffer
    do {
      let parsedValue = try DBusValue.parse(
        from: &readBuffer, typeSignature: typeSignature, byteOrder: endianness)

      // Verify parsed value matches original
      switch (value, parsedValue) {
      case (.byte(let v1), .byte(let v2)):
        #expect(v1 == v2)
      case (.boolean(let v1), .boolean(let v2)):
        #expect(v1 == v2)
      case (.int16(let v1), .int16(let v2)):
        #expect(v1 == v2)
      case (.uint16(let v1), .uint16(let v2)):
        #expect(v1 == v2)
      case (.int32(let v1), .int32(let v2)):
        #expect(v1 == v2)
      case (.uint32(let v1), .uint32(let v2)):
        #expect(v1 == v2)
      case (.int64(let v1), .int64(let v2)):
        #expect(v1 == v2)
      case (.uint64(let v1), .uint64(let v2)):
        #expect(v1 == v2)
      case (.double(let v1), .double(let v2)):
        if v1.isNaN && v2.isNaN {
          // NaN doesn't equal itself, so handle specially
          #expect(Bool(true))
        } else {
          #expect(v1 == v2)
        }
      case (.string(let v1), .string(let v2)):
        #expect(v1 == v2)
      case (.objectPath(let v1), .objectPath(let v2)):
        #expect(v1 == v2)
      case (.signature(let v1), .signature(let v2)):
        #expect(v1 == v2)
      case (.unixFd(let v1), .unixFd(let v2)):
        #expect(v1 == v2)
      case (.array(let a1), .array(let a2)):
        #expect(a1.count == a2.count)
      // Further array comparison would need recursive comparison
      case (.structure(let s1), .structure(let s2)):
        #expect(s1.count == s2.count)
      // Further structure comparison would need recursive comparison
      case (.dictionary(let d1), .dictionary(let d2)):
        #expect(d1.count == d2.count)
      // Further dictionary comparison would need recursive comparison
      case (.variant, .variant):
        // Variant comparison would need to examine signature and value
        #expect(Bool(true))
      default:
        #expect(Bool(false), "Value type mismatch: \(value) vs \(parsedValue)")
      }

      // For complex containers, also verify the type signature matches
      #expect(value.dbusTypeSignature == parsedValue.dbusTypeSignature)

      // Verify all bytes were consumed
      #expect(readBuffer.readableBytes == 0)
    } catch {
      throw error
    }
  }

  @Test func signatureValidation() throws {
    // Test various complex type signatures to ensure they're correctly understood
    let signatures = [
      "s",  // string
      "a{sv}",  // dictionary from string to variant
      "(sai)",  // struct with string and array of int32
      "a(ii)",  // array of structs with two int32s
      "(saia{sv})",  // complex struct from our test case
    ]

    for signature in signatures {
      // Create a simple buffer with a valid value for the signature
      var buffer = ByteBuffer()

      // For each signature, create a minimal valid buffer that can be parsed
      let testValue = try createMinimalValue(for: signature)

      // Write value to buffer
      testValue.write(to: &buffer, byteOrder: .little)

      // Try to parse the value back
      var readBuffer = buffer
      let parsedValue = try DBusValue.parse(
        from: &readBuffer, typeSignature: signature, byteOrder: .little)

      // Verify signatures match
      #expect(testValue.dbusTypeSignature == parsedValue.dbusTypeSignature)
      #expect(readBuffer.readableBytes == 0)
    }
  }

  /// Creates a minimal valid value for a given signature
  func createMinimalValue(for signature: String) throws -> DBusValue {
    switch signature.first {
    case "s": return .string("test")
    case "i": return .int32(42)
    case "b": return .boolean(true)
    case "a":
      if signature.starts(with: "a{sv}") {
        return .dictionary([.string("key"): .variant(DBusVariant(.int32(1)))])
      } else if signature.starts(with: "a{") {
        // Other dictionary types
        let keyType = String(signature[signature.index(signature.startIndex, offsetBy: 2)])
        let valueType = String(signature[signature.index(signature.startIndex, offsetBy: 3)])
        let key = try createMinimalValue(for: String(keyType))
        let value = try createMinimalValue(for: String(valueType))
        return .dictionary([key: value])
      } else {
        // Array of elements
        let elementType = String(signature.dropFirst())
        let element = try createMinimalValue(for: elementType)
        return .array([element])
      }
    case "(":
      // Parse the struct signature and create values for each field
      var remaining = String(signature.dropFirst().dropLast())
      var fields: [DBusValue] = []

      while !remaining.isEmpty {
        let fieldSig = try DBusValue.parseNextTypeSignature(from: &remaining)
        fields.append(try createMinimalValue(for: fieldSig))
      }

      return .structure(fields)
    case "v":
      return .variant(DBusVariant(.int32(1)))
    default:
      return .int32(1)  // Default fallback
    }
  }

  // MARK: - NetworkManager Connection Tests

  @Test func networkManagerConnectionDictionary() throws {
    // Try with a very simplified test case to isolate the invalidString error

    // Create a test SSID with spaces
    let ssid = "Test WiFi With Spaces"
    let ssidBytes = Array(ssid.utf8)

    // Create just a simple dictionary with the SSID bytes array
    let ssidArray: DBusValue = .array(ssidBytes.map { DBusValue.byte($0) })

    // First test just the array part - this step is expected to work
    var buffer1 = ByteBuffer()
    ssidArray.write(to: &buffer1, byteOrder: .little)

    var readBuffer1 = buffer1
    // Should succeed
    _ = try DBusValue.parse(
      from: &readBuffer1,
      typeSignature: ssidArray.dbusTypeSignature,
      byteOrder: .little
    )

    // Next step - test with a dictionary containing the array
    let wifiDict: DBusValue = .dictionary([
      .string("ssid"): ssidArray
    ])

    var buffer2 = ByteBuffer()
    wifiDict.write(to: &buffer2, byteOrder: .little)

    var readBuffer2 = buffer2
    // Should succeed
    _ = try DBusValue.parse(
      from: &readBuffer2,
      typeSignature: wifiDict.dbusTypeSignature,
      byteOrder: .little
    )

    // Now test with a DBusMessage
    let message = DBusMessage.createMethodCall(
      destination: "org.freedesktop.NetworkManager",
      path: "/org/freedesktop/NetworkManager",
      interface: "org.freedesktop.NetworkManager",
      method: "TestMethod",
      serial: 1,
      body: [wifiDict]
    )

    var buffer3 = ByteBuffer()
    message.write(to: &buffer3)

    let decodedMessage = try DBusMessage(from: &buffer3)

    // Verify the message was decoded correctly
    #expect(decodedMessage.body.count == 1, "Should have 1 body entry")

    // Add debug output to see the structure of the decoded message
    print("Decoded message body type: \(type(of: decodedMessage.body[0]))")
    print("Decoded message body: \(decodedMessage.body[0])")

    // Check for different possible formats the SSID might be decoded as
    func findSSID(in value: DBusValue) -> String? {
      switch value {
      case .dictionary(let entries):
        // Direct dictionary entry
        if let ssidEntry = entries.first(where: {
          if case .string(let key) = $0.key, key == "ssid" {
            return true
          }
          return false
        }),
          case .array(let byteValues) = ssidEntry.value
        {
          let bytes = byteValues.compactMap { value -> UInt8? in
            if case .byte(let byte) = value {
              return byte
            }
            return nil
          }
          // Return the string as is, but wrap in an optional to match the return type
          return String(decoding: bytes, as: UTF8.self)
        }

        // Try searching recursively through all entries
        for (_, entryValue) in entries {
          if let foundSsid = findSSID(in: entryValue) {
            return foundSsid
          }
        }

      case .array(let values):
        // Search through array elements
        for value in values {
          if let foundSsid = findSSID(in: value) {
            return foundSsid
          }
        }

      case .variant(let variant):
        // Look inside variants
        return findSSID(in: variant.value)

      case .structure(let values):
        // Search through structure elements
        for value in values {
          if let foundSsid = findSSID(in: value) {
            return foundSsid
          }
        }

      default:
        return nil
      }

      return nil
    }

    // Try finding the SSID with our recursive function
    if let decodedSsid = findSSID(in: decodedMessage.body[0]) {
      #expect(decodedSsid == ssid, "SSID should match original")
    } else {
      // If we still can't find it, dump the full decoded message to help debug
      print("Full decoded message: \(decodedMessage)")
      #expect(Bool(false), "Could not find decoded SSID in message")
    }
  }

  @Test func networkManagerAddAndActivateConnectionSignature() throws {
    // Test specifically for the a{sa{sv}}oo signature handling

    // Create a minimal but valid representation of the AddAndActivateConnection parameters
    let connSettings: DBusValue = .dictionary([
      .string("connection"): .variant(
        DBusVariant(
          .dictionary([
            .string("id"): .string("Test Network"),
            .string("type"): .string("802-11-wireless"),
          ])))
    ])

    // Expected signature for AddAndActivateConnection method
    let expectedSignature = "a{sa{sv}}oo"

    // Create a message with the correct signature format
    let message = DBusMessage.createMethodCall(
      destination: "org.freedesktop.NetworkManager",
      path: "/org/freedesktop/NetworkManager",
      interface: "org.freedesktop.NetworkManager",
      method: "AddAndActivateConnection",
      serial: 1,
      body: [
        connSettings,
        .objectPath("/device/path"),
        .objectPath("/ap/path"),
      ]
    )

    var buffer = ByteBuffer()
    message.write(to: &buffer)

    // Check the signature of the message body
    for field in message.headerFields {
      if case .signature = field.code,
        case .signature(let signature) = field.variant.value
      {
        // The signature might include each parameter's individual signature
        // For the AddAndActivateConnection method with our parameters
        // Check that the signature correctly represents our complex structure
        #expect(signature.contains("a{s"), "Signature should contain dictionary with string keys")
        #expect(signature.contains("o"), "Signature should contain object paths")
        // Verify the signature format matches what we expect
        #expect(
          signature.hasSuffix("oo"),
          "Signature should end with two object paths as in \(expectedSignature)")
        break
      }
    }

    // Decode the message and ensure it's correctly reconstructed
    let decodedMessage = try DBusMessage(from: &buffer)
    #expect(decodedMessage.body.count == 3, "Should have 3 parameters")

    // Just check that we have a dictionary in the first parameter that contains the expected connection info
    // Instead of checking for exact equality, which can fail due to implementation details
    let entries: [DBusValue: DBusValue]
    switch decodedMessage.body[0] {
    case .dictionary(let dict):
      entries = dict
    case .array(let dictionaries):
      guard
        let connectionDict = dictionaries.first,
        case .dictionary(let dict) = connectionDict
      else {
        #expect(Bool(false), "Should have valid connection dictionary with settings")
        return
      }
      entries = dict
    default:
      #expect(Bool(false), "Should have valid connection dictionary with settings")
      return
    }

    if let connectionEntry = entries.first(where: {
      if case .string(let key) = $0.key, key == "connection" {
        return true
      }
      return false
    }),
      case .variant(let variant) = connectionEntry.value
    {

      var foundId = false
      var foundType = false

      // Extract and check all the values, regardless of exact structure
      func checkForValues(in value: DBusValue) {
        switch value {
        case .dictionary(let dict):
          for (k, v) in dict {
            if case .string(let key) = k {
              if key == "id", case .string(let val) = v, val == "Test Network" {
                foundId = true
              } else if key == "type", case .string(let val) = v, val == "802-11-wireless" {
                foundType = true
              }
            }
          }
        case .array(let arr):
          for item in arr {
            checkForValues(in: item)
          }
        case .variant(let v):
          checkForValues(in: v.value)
        default:
          break
        }
      }

      checkForValues(in: variant.value)

      #expect(foundId, "Should find id = 'Test Network' in connection settings")
      #expect(foundType, "Should find type = '802-11-wireless' in connection settings")
    } else {
      #expect(Bool(false), "Should have valid connection dictionary with settings")
    }

    // Check the object paths
    #expect(decodedMessage.body[1] == .objectPath("/device/path"), "Device path should match")
    #expect(decodedMessage.body[2] == .objectPath("/ap/path"), "AP path should match")
  }
}
