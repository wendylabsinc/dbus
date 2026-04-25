import Testing
@testable import DBusCodegen

@Suite
struct TypeMapperTests {
  @Test func primitiveTypesMap() {
    #expect(TypeMapper.swiftType(for: "y") == "UInt8")
    #expect(TypeMapper.swiftType(for: "b") == "Bool")
    #expect(TypeMapper.swiftType(for: "n") == "Int16")
    #expect(TypeMapper.swiftType(for: "q") == "UInt16")
    #expect(TypeMapper.swiftType(for: "i") == "Int32")
    #expect(TypeMapper.swiftType(for: "u") == "UInt32")
    #expect(TypeMapper.swiftType(for: "x") == "Int64")
    #expect(TypeMapper.swiftType(for: "t") == "UInt64")
    #expect(TypeMapper.swiftType(for: "d") == "Double")
  }

  @Test func stringTypesMap() {
    #expect(TypeMapper.swiftType(for: "s") == "String")
    #expect(TypeMapper.swiftType(for: "o") == "String")
    #expect(TypeMapper.swiftType(for: "g") == "String")
  }

  @Test func specialTypesMap() {
    #expect(TypeMapper.swiftType(for: "h") == "UInt32")
    #expect(TypeMapper.swiftType(for: "v") == "DBusVariant")
  }

  @Test func arrayTypesMap() {
    #expect(TypeMapper.swiftType(for: "ay") == "[UInt8]")
    #expect(TypeMapper.swiftType(for: "as") == "[String]")
    #expect(TypeMapper.swiftType(for: "a{sv}") == "[String: DBusVariant]")
    #expect(TypeMapper.swiftType(for: "a{ss}") == "[String: String]")
  }

  @Test func unknownTypesFallBack() {
    #expect(TypeMapper.swiftType(for: "(ii)") == "DBusValue")
    #expect(TypeMapper.swiftType(for: "a(ii)") == "DBusValue")
  }

  @Test func encodeSimpleTypes() {
    #expect(TypeMapper.encodeExpression("x", signature: "y") == ".byte(x)")
    #expect(TypeMapper.encodeExpression("x", signature: "b") == ".boolean(x)")
    #expect(TypeMapper.encodeExpression("x", signature: "i") == ".int32(x)")
    #expect(TypeMapper.encodeExpression("x", signature: "s") == ".string(x)")
    #expect(TypeMapper.encodeExpression("x", signature: "o") == ".objectPath(x)")
    #expect(TypeMapper.encodeExpression("x", signature: "v") == ".variant(x)")
  }

  @Test func encodeArrayTypes() {
    #expect(TypeMapper.encodeExpression("x", signature: "ay") == ".array(x.map { .byte($0) })")
    #expect(TypeMapper.encodeExpression("x", signature: "as") == ".array(x.map { .string($0) })")
  }

  @Test func encodeDictTypes() {
    let expr = TypeMapper.encodeExpression("x", signature: "a{sv}")
    #expect(expr == ".dictionary(Dictionary(uniqueKeysWithValues: x.map { (.string($0.key), .variant($0.value)) }))")
  }

  @Test func encodeUnknownPassesThrough() {
    #expect(TypeMapper.encodeExpression("x", signature: "(ii)") == "x")
  }

  @Test func decodeSimpleType() {
    let lines = TypeMapper.decodeLines(0, signature: "s")
    #expect(lines.count == 3)
    #expect(lines[0].contains("reply.body.indices.contains(0)"))
    #expect(lines[1].contains("guard case .string"))
    #expect(lines[2] == "return _v0")
  }

  @Test func decodeArrayOfBytes() {
    let lines = TypeMapper.decodeLines(0, signature: "ay")
    #expect(lines.count == 3)
    #expect(lines[0].contains("reply.body.indices.contains(0)"))
    #expect(lines[1].contains("guard case .array"))
    #expect(lines[2].contains(".byte"))
  }

  @Test func decodeVariantLines() {
    let lines = TypeMapper.decodeVariantLines(0, signature: "s")
    #expect(lines.count == 3)
    #expect(lines[0].contains("guard case .variant(let _variant0)"))
    #expect(lines[1].contains("guard case .string") && lines[1].contains("_variant0.value"))
    #expect(lines[2] == "return _v0")
  }

  @Test func swiftIdentifierEscapesKeywords() {
    #expect(TypeMapper.swiftIdentifier("protocol") == "`protocol`")
    #expect(TypeMapper.swiftIdentifier("type") == "`type`")
    #expect(TypeMapper.swiftIdentifier("Type") == "`type`")
    #expect(TypeMapper.swiftIdentifier("default") == "`default`")
    #expect(TypeMapper.swiftIdentifier("name") == "name")
    #expect(TypeMapper.swiftIdentifier("domain") == "domain")
  }

  @Test func interfaceNameToPrefix() {
    #expect(TypeMapper.interfacePrefix("org.bluez.GattCharacteristic1") == "OrgBluezGattCharacteristic1")
    #expect(TypeMapper.interfacePrefix("org.freedesktop.DBus") == "OrgFreedesktopDBus")
  }

  @Test func lowerCamelCase() {
    #expect(TypeMapper.lowerCamelCase("UUID") == "uuid")
    #expect(TypeMapper.lowerCamelCase("ReadValue") == "readValue")
    #expect(TypeMapper.lowerCamelCase("value") == "value")
  }
}
