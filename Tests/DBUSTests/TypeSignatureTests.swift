import NIOCore
import Testing

@testable import DBUS

@Suite
struct TypeSignatureTests {
  // MARK: - Valid Signatures

  @Test func basicTypes() throws {
    // Test all basic types individually
    try validateSignature("y", [.byte])
    try validateSignature("b", [.boolean])
    try validateSignature("n", [.int16])
    try validateSignature("q", [.uint16])
    try validateSignature("i", [.int32])
    try validateSignature("u", [.uint32])
    try validateSignature("x", [.int64])
    try validateSignature("t", [.uint64])
    try validateSignature("d", [.double])
    try validateSignature("s", [.string])
    try validateSignature("o", [.objectPath])
    try validateSignature("g", [.signature])
    try validateSignature("h", [.unixFd])
    try validateSignature("v", [.variant])
  }

  @Test func multipleBasicTypes() throws {
    // Test multiple consecutive basic types
    try validateSignature(
      "ybnqiuxtdsogvh",
      [
        .byte, .boolean, .int16, .uint16, .int32, .uint32, .int64,
        .uint64, .double, .string, .objectPath, .signature, .variant, .unixFd,
      ])
  }

  @Test func arrayTypes() throws {
    // Test arrays of various types
    try validateSignature("ay", [.array(.byte)])
    try validateSignature("as", [.array(.string)])
    try validateSignature("aay", [.array(.array(.byte))])
    try validateSignature("a(is)", [.array(.structure([.int32, .string]))])
  }

  @Test func structTypes() throws {
    // Test structs with various combinations
    try validateSignature("(y)", [.structure([.byte])])
    try validateSignature("(iy)", [.structure([.int32, .byte])])
    try validateSignature("(isav)", [.structure([.int32, .string, .array(.variant)])])
  }

  @Test func dictionaryTypes() throws {
    // Test dictionary entries with various key and value types
    try validateSignature("a{sy}", [.array(.dictEntry(key: .string, value: .byte))])
    try validateSignature("a{is}", [.array(.dictEntry(key: .int32, value: .string))])
    try validateSignature("a{uav}", [.array(.dictEntry(key: .uint32, value: .array(.variant)))])
  }

  @Test func complexTypes() throws {
    // Test complex nested types
    try validateSignature(
      "a{s(iai)}",
      [
        .array(.dictEntry(key: .string, value: .structure([.int32, .array(.int32)])))
      ])

    try validateSignature(
      "(a{sv}ay)",
      [
        .structure([
          .array(.dictEntry(key: .string, value: .variant)),
          .array(.byte),
        ])
      ])

    // Test with a very complex nesting but within limits
    try validateSignature(
      "a{sa{ia{ba{na{qa{ia(syv)}}}}}}",
      [
        .array(
          .dictEntry(
            key: .string,
            value: .array(
              .dictEntry(
                key: .int32,
                value: .array(
                  .dictEntry(
                    key: .boolean,
                    value: .array(
                      .dictEntry(
                        key: .int16,
                        value: .array(
                          .dictEntry(
                            key: .uint16,
                            value: .array(
                              .dictEntry(
                                key: .int32,
                                value: .array(.structure([.string, .byte, .variant]))
                              ))
                          ))
                      ))
                  ))
              ))
          ))
      ])
  }

  // MARK: - Error Cases

  @Test func emptySignature() throws {
    // Empty signatures are valid (empty array of types)
    try validateSignature("", [])
  }

  @Test func invalidCharacters() throws {
    // Test invalid type characters
    do {
      let _ = try DBusTypeSignature("z")
      #expect(Bool(false), "Expected error for invalid character 'z'")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .invalidTypeChar("z"))
    }

    do {
      let _ = try DBusTypeSignature("?")
      #expect(Bool(false), "Expected error for invalid character '?'")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .invalidTypeChar("?"))
    }

    do {
      let _ = try DBusTypeSignature("$")
      #expect(Bool(false), "Expected error for invalid character '$'")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .invalidTypeChar("$"))
    }
  }

  @Test func unexpectedEnd() throws {
    // Test unexpected end of signature
    do {
      let _ = try DBusTypeSignature("a")
      #expect(Bool(false), "Expected unexpectedEnd error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .unexpectedEnd)
    }

    do {
      let _ = try DBusTypeSignature("(i")
      #expect(Bool(false), "Expected unmatchedParenthesis error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .unmatchedParenthesis)
    }

    do {
      let _ = try DBusTypeSignature("a{i")
      #expect(Bool(false), "Expected unmatchedBrace error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .unmatchedBrace)
    }
  }

  @Test func unmatchedDelimiters() throws {
    // Test unmatched delimiters
    do {
      let _ = try DBusTypeSignature("(is")
      #expect(Bool(false), "Expected unmatchedParenthesis error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .unmatchedParenthesis)
    }

    do {
      let _ = try DBusTypeSignature("i)")
      #expect(Bool(false), "Expected invalidTypeChar error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .invalidTypeChar(")"))
    }

    do {
      let _ = try DBusTypeSignature("a{is")
      #expect(Bool(false), "Expected unmatchedBrace error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .unmatchedBrace)
    }

    do {
      let _ = try DBusTypeSignature("i}")
      #expect(Bool(false), "Expected invalidTypeChar error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .invalidTypeChar("}"))
    }
  }

  @Test func invalidDictionaryKeys() throws {
    // Only basic types can be dictionary keys
    do {
      let _ = try DBusTypeSignature("a{(i)s}")
      #expect(Bool(false), "Expected invalidDictKey error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .invalidDictKey)
    }

    do {
      let _ = try DBusTypeSignature("a{vis}")
      #expect(Bool(false), "Expected invalidDictKey error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .invalidDictKey)
    }

    do {
      let _ = try DBusTypeSignature("a{ais}")
      #expect(Bool(false), "Expected invalidDictKey error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .invalidDictKey)
    }
  }

  @Test func dictEntryOutsideArray() throws {
    do {
      let _ = try DBusTypeSignature("{sv}")
      #expect(Bool(false), "Expected dictEntryOutsideArray error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .dictEntryOutsideArray)
    }
  }

  @Test func emptyStructs() throws {
    // Empty structs are not allowed
    do {
      let _ = try DBusTypeSignature("()")
      #expect(Bool(false), "Expected emptyStruct error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .emptyStruct)
    }

    do {
      let _ = try DBusTypeSignature("a()")
      #expect(Bool(false), "Expected emptyStruct error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .emptyStruct)
    }
  }

  @Test func tooLong() throws {
    // Test signatures that exceed 255 bytes
    let longSignature = String(repeating: "i", count: 256)
    do {
      let _ = try DBusTypeSignature(longSignature)
      #expect(Bool(false), "Expected tooLong error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .tooLong)
    }
  }

  @Test func tooDeep() throws {
    // Test array nesting that exceeds 32 levels
    let deepArrays = String(repeating: "a", count: 33) + "i"
    do {
      let _ = try DBusTypeSignature(deepArrays)
      #expect(Bool(false), "Expected tooDeep error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .tooDeep)
    }

    // Test struct nesting that exceeds 32 levels
    let deepStructStart = String(repeating: "(", count: 33)
    let deepStructEnd = String(repeating: ")", count: 33)
    do {
      let _ = try DBusTypeSignature(deepStructStart + "i" + deepStructEnd)
      #expect(Bool(false), "Expected tooDeep error")
    } catch let error as DBusTypeSignature.Error {
      #expect(error == .tooDeep)
    }
  }

  // MARK: - Helper Methods

  func validateSignature(_ raw: String, _ expectedTypes: [DBusType]) throws {
    let signature = try DBusTypeSignature(raw)
    #expect(signature.raw == raw)
    #expect(signature.types == expectedTypes)
  }
}

// Extend DBusType to conform to Equatable for testing
extension DBusType: Equatable {
  public static func == (lhs: DBusType, rhs: DBusType) -> Bool {
    switch (lhs, rhs) {
    case (.byte, .byte),
      (.boolean, .boolean),
      (.int16, .int16),
      (.uint16, .uint16),
      (.int32, .int32),
      (.uint32, .uint32),
      (.int64, .int64),
      (.uint64, .uint64),
      (.double, .double),
      (.string, .string),
      (.objectPath, .objectPath),
      (.signature, .signature),
      (.unixFd, .unixFd),
      (.variant, .variant):
      return true
    case (.array(let lelem), .array(let relem)):
      return lelem == relem
    case (.dictEntry(let lkey, let lval), .dictEntry(let rkey, let rval)):
      return lkey == rkey && lval == rval
    case (.structure(let lelems), .structure(let relems)):
      return lelems == relems
    default:
      return false
    }
  }
}

// Extend Error enum to conform to Equatable for testing
extension DBusTypeSignature.Error: Equatable {
  public static func == (lhs: DBusTypeSignature.Error, rhs: DBusTypeSignature.Error) -> Bool {
    switch (lhs, rhs) {
    case (.unexpectedEnd, .unexpectedEnd),
      (.unmatchedParenthesis, .unmatchedParenthesis),
      (.unmatchedBrace, .unmatchedBrace),
      (.extraCharacters, .extraCharacters),
      (.tooLong, .tooLong),
      (.tooDeep, .tooDeep),
      (.emptyStruct, .emptyStruct),
      (.invalidDictKey, .invalidDictKey),
      (.dictEntryOutsideArray, .dictEntryOutsideArray):
      return true
    case (.invalidTypeChar(let lc), .invalidTypeChar(let rc)):
      return lc == rc
    default:
      return false
    }
  }
}
