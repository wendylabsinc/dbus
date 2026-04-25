public enum TypeMapper {
  public static func swiftType(for signature: String) -> String {
    switch signature {
    case "y": return "UInt8"
    case "b": return "Bool"
    case "n": return "Int16"
    case "q": return "UInt16"
    case "i": return "Int32"
    case "u": return "UInt32"
    case "x": return "Int64"
    case "t": return "UInt64"
    case "d": return "Double"
    case "s", "o", "g": return "String"
    case "h": return "UInt32"
    case "v": return "DBusVariant"
    case "ay": return "[UInt8]"
    case "as": return "[String]"
    case "a{sv}": return "[String: DBusVariant]"
    case "a{ss}": return "[String: String]"
    default: return "DBusValue"
    }
  }

  public static func encodeExpression(_ name: String, signature: String) -> String {
    switch signature {
    case "y": return ".byte(\(name))"
    case "b": return ".boolean(\(name))"
    case "n": return ".int16(\(name))"
    case "q": return ".uint16(\(name))"
    case "i": return ".int32(\(name))"
    case "u": return ".uint32(\(name))"
    case "x": return ".int64(\(name))"
    case "t": return ".uint64(\(name))"
    case "d": return ".double(\(name))"
    case "s": return ".string(\(name))"
    case "o": return ".objectPath(\(name))"
    case "g": return ".signature(\(name))"
    case "h": return ".unixFd(\(name))"
    case "v": return ".variant(\(name))"
    case "ay": return ".array(\(name).map { .byte($0) })"
    case "as": return ".array(\(name).map { .string($0) })"
    case "a{sv}":
      return
        ".dictionary(Dictionary(uniqueKeysWithValues: \(name).map { (.string($0.key), .variant($0.value)) }))"
    case "a{ss}":
      return
        ".dictionary(Dictionary(uniqueKeysWithValues: \(name).map { (.string($0.key), .string($0.value)) }))"
    default: return name
    }
  }

  public static func decodeLines(
    _ index: Int, signature: String, sourceExpr: String? = nil
  ) -> [String] {
    let src = sourceExpr ?? "reply.body[\(index)]"
    let v = "_v\(index)"
    switch signature {
    case "y":
      return [
        "guard case .byte(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "b":
      return [
        "guard case .boolean(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "n":
      return [
        "guard case .int16(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "q":
      return [
        "guard case .uint16(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "i":
      return [
        "guard case .int32(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "u":
      return [
        "guard case .uint32(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "x":
      return [
        "guard case .int64(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "t":
      return [
        "guard case .uint64(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "d":
      return [
        "guard case .double(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "s":
      return [
        "guard case .string(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "o":
      return [
        "guard case .objectPath(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "g":
      return [
        "guard case .signature(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "h":
      return [
        "guard case .unixFd(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "v":
      return [
        "guard case .variant(let \(v)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return \(v)",
      ]
    case "ay":
      let arr = "_arr\(index)"
      return [
        "guard case .array(let \(arr)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return try \(arr).map { elem in guard case .byte(let b) = elem else { throw DBusCodegenError.typeMismatch }; return b }",
      ]
    case "as":
      let arr = "_arr\(index)"
      return [
        "guard case .array(let \(arr)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return try \(arr).map { elem in guard case .string(let s) = elem else { throw DBusCodegenError.typeMismatch }; return s }",
      ]
    case "a{sv}":
      let d = "_dict\(index)"
      return [
        "guard case .dictionary(let \(d)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return try Dictionary(uniqueKeysWithValues: \(d).map { k, v in",
        "    guard case .string(let key) = k, case .variant(let val) = v else { throw DBusCodegenError.typeMismatch }",
        "    return (key, val)",
        "})",
      ]
    case "a{ss}":
      let d = "_dict\(index)"
      return [
        "guard case .dictionary(let \(d)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "return try Dictionary(uniqueKeysWithValues: \(d).map { k, v in",
        "    guard case .string(let key) = k, case .string(let val) = v else { throw DBusCodegenError.typeMismatch }",
        "    return (key, val)",
        "})",
      ]
    default:
      return ["return \(src)"]
    }
  }

  public static func decodeVariantLines(_ index: Int, signature: String) -> [String] {
    let src = "reply.body[\(index)]"
    let variantVar = "_variant\(index)"
    let inner = TypeMapper.decodeLines(
      index, signature: signature, sourceExpr: "\(variantVar).value")
    return [
      "guard case .variant(let \(variantVar)) = \(src) else { throw DBusCodegenError.typeMismatch }"
    ] + inner
  }

  public static func interfacePrefix(_ interfaceName: String) -> String {
    interfaceName.split(separator: ".").map { part -> String in
      let s = String(part)
      return s.prefix(1).uppercased() + s.dropFirst()
    }.joined()
  }

  private static let swiftKeywords: Set<String> = [
    "Any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
    "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
    "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard",
    "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating",
    "nil", "nonmutating", "open", "operator", "override", "postfix", "precedencegroup",
    "prefix", "private", "protocol", "public", "repeat", "required", "rethrows",
    "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super",
    "switch", "throw", "throws", "true", "try", "type", "typealias", "unowned", "var",
    "weak", "where", "while", "willSet", "didSet",
  ]

  public static func swiftIdentifier(_ name: String) -> String {
    let camel = lowerCamelCase(name)
    return swiftKeywords.contains(camel) ? "`\(camel)`" : camel
  }

  public static func lowerCamelCase(_ s: String) -> String {
    guard let first = s.first else { return s }
    // Handle snake_case: split on underscores and camelCase the result
    if s.contains("_") {
      let parts = s.split(separator: "_", omittingEmptySubsequences: true)
      guard !parts.isEmpty else { return s }
      let first = String(parts[0]).lowercased()
      let rest = parts.dropFirst().map { part -> String in
        let p = String(part)
        return p.prefix(1).uppercased() + p.dropFirst()
      }
      return ([first] + rest).joined()
    }
    if !s.contains(where: { $0.isLowercase }) {
      return s.lowercased()
    }
    return first.lowercased() + s.dropFirst()
  }
}
