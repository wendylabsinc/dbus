public enum ServerGenerator {
  public static func generate(interface: DBusInterface, into writer: inout CodeWriter) {
    let prefix = TypeMapper.interfacePrefix(interface.name)

    // ── Handler protocol ──────────────────────────────────────────────────
    writer.writeLine("public protocol \(prefix)Handler: Sendable {")
    writer.indent { w in
      for method in interface.methods {
        w.writeLine(handlerMethodSignature(method))
      }
      for property in interface.properties {
        if property.access == .read || property.access == .readWrite {
          w.writeLine(
            "var \(TypeMapper.lowerCamelCase(property.name)): \(TypeMapper.swiftType(for: property.type)) { get async throws }"
          )
        }
        if property.access == .write || property.access == .readWrite {
          w.writeLine(
            "func set\(property.name)(_ newValue: \(TypeMapper.swiftType(for: property.type))) async throws"
          )
        }
      }
    }
    writer.writeLine("}")
    writer.writeLine()

    // ── makeInterface() extension ─────────────────────────────────────────
    writer.writeLine("extension \(prefix)Handler {")
    writer.indent { w in
      w.writeLine("public func makeInterface() -> DBusObjectServer.Interface {")
      w.indent { w2 in
        w2.writeLine("var iface = DBusObjectServer.Interface(name: \"\(interface.name)\")")
        w2.writeLine("iface.methods = [")
        w2.indent { w3 in
          for method in interface.methods {
            generateMethodBridge(method, into: &w3)
          }
        }
        w2.writeLine("]")
        if !interface.properties.isEmpty {
          w2.writeLine("iface.properties = [")
          w2.indent { w3 in
            for property in interface.properties {
              generatePropertyBridge(property, into: &w3)
            }
          }
          w2.writeLine("]")
        }
        w2.writeLine("return iface")
      }
      w.writeLine("}")
    }
    writer.writeLine("}")
  }

  private static func handlerMethodSignature(_ method: DBusMethod) -> String {
    let name = TypeMapper.swiftIdentifier(method.name)
    let params = method.inArgs.map { arg in
      "\(TypeMapper.swiftIdentifier(arg.name)): \(TypeMapper.swiftType(for: arg.type))"
    }.joined(separator: ", ")
    let returnClause: String
    switch method.outArgs.count {
    case 0: returnClause = ""
    case 1: returnClause = " -> \(TypeMapper.swiftType(for: method.outArgs[0].type))"
    default:
      let tuple = method.outArgs.map { arg in
        "\(TypeMapper.swiftIdentifier(arg.name)): \(TypeMapper.swiftType(for: arg.type))"
      }.joined(separator: ", ")
      returnClause = " -> (\(tuple))"
    }
    return "func \(name)(\(params)) async throws\(returnClause)"
  }

  private static func generateMethodBridge(_ method: DBusMethod, into writer: inout CodeWriter) {
    let inArgDecls =
      method.inArgs.isEmpty
      ? "[]"
      : "["
        + method.inArgs.map { ".init(name: \"\($0.name)\", type: \"\($0.type)\")" }.joined(
          separator: ", ") + "]"
    let outArgDecls =
      method.outArgs.isEmpty
      ? "[]"
      : "["
        + method.outArgs.map { ".init(name: \"\($0.name)\", type: \"\($0.type)\")" }.joined(
          separator: ", ") + "]"
    writer.writeLine(
      ".init(name: \"\(method.name)\", inputArgs: \(inArgDecls), outputArgs: \(outArgDecls)) { [self] ctx in"
    )
    writer.indent { w in
      // Decode in-args
      for (i, arg) in method.inArgs.enumerated() {
        let swiftName = TypeMapper.swiftIdentifier(arg.name)
        let src = "ctx.arguments[\(i)]"
        let lines = inlineDecodeLines(src: src, signature: arg.type, resultName: swiftName)
        w.writeLines(lines)
      }

      // Call handler
      let callArgs = method.inArgs.map { arg in
        let label = TypeMapper.lowerCamelCase(arg.name)
        let value = TypeMapper.swiftIdentifier(arg.name)
        return "\(label): \(value)"
      }.joined(separator: ", ")
      let handlerCall = "try await self.\(TypeMapper.lowerCamelCase(method.name))(\(callArgs))"

      if method.outArgs.isEmpty {
        w.writeLine("\(handlerCall)")
        w.writeLine("return []")
      } else if method.outArgs.count == 1 {
        w.writeLine("let result = \(handlerCall)")
        let encoded = TypeMapper.encodeExpression("result", signature: method.outArgs[0].type)
        w.writeLine("return [\(encoded)]")
      } else {
        w.writeLine("let result = \(handlerCall)")
        let encoded = method.outArgs.map { arg in
          TypeMapper.encodeExpression(
            "result.\(TypeMapper.swiftIdentifier(arg.name))", signature: arg.type)
        }.joined(separator: ", ")
        w.writeLine("return [\(encoded)]")
      }
    }
    writer.writeLine("},")
  }

  private static func generatePropertyBridge(
    _ property: DBusProperty, into writer: inout CodeWriter
  ) {
    let propName = TypeMapper.swiftIdentifier(property.name)
    let access: String
    switch property.access {
    case .read: access = ".read"
    case .write: access = ".write"
    case .readWrite: access = ".readWrite"
    }

    let hasGetter = property.access == .read || property.access == .readWrite
    let hasSetter = property.access == .write || property.access == .readWrite

    if !hasSetter {
      let getterCode: String
      if hasGetter {
        let encoded = TypeMapper.encodeExpression(
          "try await self.\(propName)", signature: property.type)
        getterCode = "{ [self] _ in \(encoded) }"
      } else {
        getterCode = "{ _ in DBusValue.boolean(false) }"
      }
      writer.writeLine(
        ".init(name: \"\(property.name)\", signature: \"\(property.type)\", access: \(access), get: \(getterCode)),"
      )
    } else {
      let getterCode: String
      if hasGetter {
        let encoded = TypeMapper.encodeExpression(
          "try await self.\(propName)", signature: property.type)
        getterCode = "{ [self] _ in \(encoded) }"
      } else {
        getterCode = "{ _ in DBusValue.boolean(false) }"
      }
      writer.writeLine(
        ".init(name: \"\(property.name)\", signature: \"\(property.type)\", access: \(access), get: \(getterCode), set: { [self] _newVal, _ in"
      )
      writer.indent { w in
        let decodeLines = inlineDecodeLines(
          src: "_newVal", signature: property.type, resultName: "_decoded")
        w.writeLines(decodeLines)
        w.writeLine("try await self.set\(property.name)(_decoded)")
      }
      writer.writeLine("}),")
    }
  }

  /// Returns lines that decode a DBusValue variable named `src` into a Swift `let` binding named `resultName`.
  private static func inlineDecodeLines(src: String, signature: String, resultName: String)
    -> [String]
  {
    switch signature {
    case "y":
      return [
        "guard case .byte(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "b":
      return [
        "guard case .boolean(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "n":
      return [
        "guard case .int16(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "q":
      return [
        "guard case .uint16(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "i":
      return [
        "guard case .int32(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "u":
      return [
        "guard case .uint32(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "x":
      return [
        "guard case .int64(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "t":
      return [
        "guard case .uint64(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "d":
      return [
        "guard case .double(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "s":
      return [
        "guard case .string(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "o":
      return [
        "guard case .objectPath(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "g":
      return [
        "guard case .signature(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "h":
      return [
        "guard case .unixFd(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "v":
      return [
        "guard case .variant(let \(resultName)) = \(src) else { throw DBusCodegenError.typeMismatch }"
      ]
    case "ay":
      let tmp = "_arr_\(resultName)"
      return [
        "guard case .array(let \(tmp)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "let \(resultName) = try \(tmp).map { elem in guard case .byte(let b) = elem else { throw DBusCodegenError.typeMismatch }; return b }",
      ]
    case "as":
      let tmp = "_arr_\(resultName)"
      return [
        "guard case .array(let \(tmp)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "let \(resultName) = try \(tmp).map { elem in guard case .string(let s) = elem else { throw DBusCodegenError.typeMismatch }; return s }",
      ]
    case "a{sv}":
      let tmp = "_d_\(resultName)"
      return [
        "guard case .dictionary(let \(tmp)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "let \(resultName) = try Dictionary(uniqueKeysWithValues: \(tmp).map { k, v in guard case .string(let key) = k, case .variant(let val) = v else { throw DBusCodegenError.typeMismatch }; return (key, val) })",
      ]
    case "a{ss}":
      let tmp = "_d_\(resultName)"
      return [
        "guard case .dictionary(let \(tmp)) = \(src) else { throw DBusCodegenError.typeMismatch }",
        "let \(resultName) = try Dictionary(uniqueKeysWithValues: \(tmp).map { k, v in guard case .string(let key) = k, case .string(let val) = v else { throw DBusCodegenError.typeMismatch }; return (key, val) })",
      ]
    default:
      return ["let \(resultName) = \(src)"]
    }
  }
}
