public enum ClientGenerator {
  public static func generate(interface: DBusInterface, into writer: inout CodeWriter) {
    let prefix = TypeMapper.interfacePrefix(interface.name)

    // --- Protocol ---
    writer.writeLine("public protocol \(prefix): Sendable {")
    writer.indent { w in
      // Methods
      for method in interface.methods {
        let methodName = TypeMapper.swiftIdentifier(method.name)
        let params = method.inArgs
          .map { "\(TypeMapper.swiftIdentifier($0.name)): \(TypeMapper.swiftType(for: $0.type))" }
          .joined(separator: ", ")
        let returnType = returnTypeString(method.outArgs)
        if returnType == "Void" {
          w.writeLine("func \(methodName)(\(params)) async throws")
        } else {
          w.writeLine("func \(methodName)(\(params)) async throws -> \(returnType)")
        }
      }
      // Properties
      for prop in interface.properties {
        let propName = TypeMapper.swiftIdentifier(prop.name)
        let swiftType = TypeMapper.swiftType(for: prop.type)
        if prop.access == .read || prop.access == .readWrite {
          w.writeLine("var \(propName): \(swiftType) { get async throws }")
        }
        if prop.access == .write || prop.access == .readWrite {
          let setterName = "set\(prop.name)"
          w.writeLine("func \(setterName)(_ newValue: \(swiftType)) async throws")
        }
      }
    }
    writer.writeLine("}")
    writer.writeLine()

    // --- Proxy struct ---
    writer.writeLine("public struct \(prefix)Proxy: \(prefix) {")
    writer.indent { w in
      w.writeLine("private let connection: DBusClient.Connection")
      w.writeLine("private let destination: String")
      w.writeLine("private let path: String")
      w.writeLine()
      w.writeLine("public init(connection: DBusClient.Connection, destination: String, path: String) {")
      w.indent { wi in
        wi.writeLine("self.connection = connection")
        wi.writeLine("self.destination = destination")
        wi.writeLine("self.path = path")
      }
      w.writeLine("}")
      w.writeLine()

      // Method implementations
      for method in interface.methods {
        generateMethodImpl(method, interfaceName: interface.name, into: &w)
        w.writeLine()
      }

      // Property implementations
      for prop in interface.properties {
        generatePropertyImpl(prop, interfaceName: interface.name, into: &w)
      }
    }
    writer.writeLine("}")
  }

  // MARK: - Internal helpers (used by Codegen.swift)

  internal static func generateMethodImpl(_ method: DBusMethod, interfaceName: String, into writer: inout CodeWriter) {
    let methodName = TypeMapper.swiftIdentifier(method.name)
    let params = method.inArgs
      .map { "\(TypeMapper.swiftIdentifier($0.name)): \(TypeMapper.swiftType(for: $0.type))" }
      .joined(separator: ", ")
    let returnType = returnTypeString(method.outArgs)
    let isVoid = returnType == "Void"
    let isMultiOut = method.outArgs.count > 1

    if isVoid {
      writer.writeLine("public func \(methodName)(\(params)) async throws {")
    } else {
      writer.writeLine("public func \(methodName)(\(params)) async throws -> \(returnType) {")
    }
    writer.indent { wi in
      // Build body array
      let bodyEntries = method.inArgs
        .map { TypeMapper.encodeExpression(TypeMapper.swiftIdentifier($0.name), signature: $0.type) }
      let bodyStr = bodyEntries.isEmpty ? "[]" : "[\(bodyEntries.joined(separator: ", "))]"

      wi.writeLine("let request = DBusRequest.createMethodCall(")
      wi.indent { wii in
        wii.writeLine("destination: destination,")
        wii.writeLine("path: path,")
        wii.writeLine("interface: \"\(interfaceName)\",")
        wii.writeLine("method: \"\(method.name)\",")
        wii.writeLine("body: \(bodyStr)")
      }
      wi.writeLine(")")

      if isVoid {
        wi.writeLine("_ = try await connection.send(request)")
      } else if isMultiOut {
        wi.writeLine("guard let reply = try await connection.send(request) else { throw DBusError.missingReply }")
        for (i, arg) in method.outArgs.enumerated() {
          let argName = TypeMapper.swiftIdentifier(arg.name)
          let lines = TypeMapper.decodeLines(i, signature: arg.type)
          // Convert the first "return <expr>" line into "let argName = <expr>".
          // This works for scalars (return _vN), arrays (return try _arr.map {...}),
          // and dicts (return try Dictionary(...) { ... }) — including multi-line dict
          // blocks where subsequent lines inside the closure also contain "return".
          var firstReturnReplaced = false
          let bound = lines.map { line -> String in
            if !firstReturnReplaced && line.hasPrefix("return ") {
              firstReturnReplaced = true
              return "let \(argName) = " + line.dropFirst("return ".count)
            }
            return line
          }
          wi.writeLines(bound)
        }
        let tupleElems = method.outArgs.map { arg in
          let n = TypeMapper.swiftIdentifier(arg.name)
          return "\(n): \(n)"
        }.joined(separator: ", ")
        wi.writeLine("return (\(tupleElems))")
      } else {
        wi.writeLine("guard let reply = try await connection.send(request) else { throw DBusError.missingReply }")
        let lines = TypeMapper.decodeLines(0, signature: method.outArgs[0].type)
        wi.writeLines(lines)
      }
    }
    writer.writeLine("}")
  }

  internal static func generatePropertyImpl(_ prop: DBusProperty, interfaceName: String, into writer: inout CodeWriter) {
    let propName = TypeMapper.swiftIdentifier(prop.name)
    let swiftType = TypeMapper.swiftType(for: prop.type)

    if prop.access == .read || prop.access == .readWrite {
      writer.writeLine("public var \(propName): \(swiftType) {")
      writer.indent { wi in
        wi.writeLine("get async throws {")
        wi.indent { wii in
          wii.writeLine("let request = DBusRequest.createMethodCall(")
          wii.indent { wiii in
            wiii.writeLine("destination: destination,")
            wiii.writeLine("path: path,")
            wiii.writeLine("interface: \"org.freedesktop.DBus.Properties\",")
            wiii.writeLine("method: \"Get\",")
            wiii.writeLine("body: [.string(\"\(interfaceName)\"), .string(\"\(prop.name)\")]")
          }
          wii.writeLine(")")
          wii.writeLine("guard let reply = try await connection.send(request) else { throw DBusError.missingReply }")
          let lines = TypeMapper.decodeVariantLines(0, signature: prop.type)
          wii.writeLines(lines)
        }
        wi.writeLine("}")
      }
      writer.writeLine("}")
      writer.writeLine()
    }

    if prop.access == .write || prop.access == .readWrite {
      let setterName = "set\(prop.name)"
      writer.writeLine("public func \(setterName)(_ newValue: \(swiftType)) async throws {")
      writer.indent { wi in
        let encExpr = TypeMapper.encodeExpression("newValue", signature: prop.type)
        wi.writeLine("let request = DBusRequest.createMethodCall(")
        wi.indent { wii in
          wii.writeLine("destination: destination,")
          wii.writeLine("path: path,")
          wii.writeLine("interface: \"org.freedesktop.DBus.Properties\",")
          wii.writeLine("method: \"Set\",")
          wii.writeLine("body: [.string(\"\(interfaceName)\"), .string(\"\(prop.name)\"), .variant(DBusVariant(\(encExpr)))]")
        }
        wi.writeLine(")")
        wi.writeLine("_ = try await connection.send(request)")
      }
      writer.writeLine("}")
      writer.writeLine()
    }
  }

  // MARK: - Private helpers

  private static func returnTypeString(_ outArgs: [DBusArg]) -> String {
    switch outArgs.count {
    case 0:
      return "Void"
    case 1:
      return TypeMapper.swiftType(for: outArgs[0].type)
    default:
      let parts = outArgs.map { "\(TypeMapper.swiftIdentifier($0.name)): \(TypeMapper.swiftType(for: $0.type))" }
      return "(\(parts.joined(separator: ", ")))"
    }
  }
}
