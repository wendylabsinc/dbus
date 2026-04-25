public enum SignalGenerator {
  public static func generateProtocolMembers(
    interface: DBusInterface, into writer: inout CodeWriter
  ) {
    for signal in interface.signals {
      writer.writeLine(
        "func \(TypeMapper.swiftIdentifier(signal.name))() async throws -> \(streamType(for: signal))"
      )
    }
  }

  public static func generateProxyImplementations(
    interface: DBusInterface, into writer: inout CodeWriter
  ) {
    for signal in interface.signals {
      writer.writeLine(
        "public func \(TypeMapper.swiftIdentifier(signal.name))() async throws -> \(streamType(for: signal)) {"
      )
      writer.indent { w in
        let matchRule = "type='signal',interface='\(interface.name)',member='\(signal.name)'"
        w.writeLine("_ = try await connection.send(DBusRequest.createMethodCall(")
        w.indent { w2 in
          w2.writeLine("destination: \"org.freedesktop.DBus\",")
          w2.writeLine("path: \"/org/freedesktop/DBus\",")
          w2.writeLine("interface: \"org.freedesktop.DBus\",")
          w2.writeLine("method: \"AddMatch\",")
          w2.writeLine("body: [.string(\"\(matchRule)\")]")
        }
        w.writeLine("))")
        w.writeLine(
          "let rawStream = await connection.subscribeToSignal(interface: \"\(interface.name)\", member: \"\(signal.name)\")"
        )

        if signal.args.isEmpty {
          w.writeLine("return AsyncStream<Void> { continuation in")
          w.indent { w2 in
            w2.writeLine("let task = Task {")
            w2.indent { w3 in
              w3.writeLine("for await _ in rawStream { continuation.yield(()) }")
              w3.writeLine("continuation.finish()")
            }
            w2.writeLine("}")
            w2.writeLine("continuation.onTermination = { _ in task.cancel() }")
          }
          w.writeLine("}")
        } else {
          let tupleType = tupleSwiftType(for: signal)
          w.writeLine("return AsyncStream<\(tupleType)> { continuation in")
          w.indent { w2 in
            w2.writeLine("let task = Task {")
            w2.indent { w3 in
              w3.writeLine("for await message in rawStream {")
              w3.indent { w4 in
                w4.writeLine("guard message.body.count >= \(signal.args.count) else { continue }")
                for (i, arg) in signal.args.enumerated() {
                  let varName = "_sig\(i)"
                  let decode = inlineDecode(
                    src: "message.body[\(i)]", signature: arg.type, varName: varName)
                  w4.writeLine("guard let \(varName) = \(decode) else { continue }")
                }
                if signal.args.count == 1 {
                  w4.writeLine("continuation.yield(_sig0)")
                } else {
                  let yieldArgs = signal.args.enumerated().map { i, arg in
                    "\(TypeMapper.lowerCamelCase(arg.name)): _sig\(i)"
                  }.joined(separator: ", ")
                  w4.writeLine("continuation.yield((\(yieldArgs)))")
                }
              }
              w3.writeLine("}")
              w3.writeLine("continuation.finish()")
            }
            w2.writeLine("}")
            w2.writeLine("continuation.onTermination = { _ in task.cancel() }")
          }
          w.writeLine("}")
        }
      }
      writer.writeLine("}")
      writer.writeLine()
    }
  }

  private static func streamType(for signal: DBusSignal) -> String {
    if signal.args.isEmpty { return "AsyncStream<Void>" }
    return "AsyncStream<\(tupleSwiftType(for: signal))>"
  }

  private static func tupleSwiftType(for signal: DBusSignal) -> String {
    if signal.args.count == 1 {
      return TypeMapper.swiftType(for: signal.args[0].type)
    }
    let fields = signal.args.map { arg in
      "\(TypeMapper.swiftIdentifier(arg.name)): \(TypeMapper.swiftType(for: arg.type))"
    }.joined(separator: ", ")
    return "(\(fields))"
  }

  private static func inlineDecode(src: String, signature: String, varName: String) -> String {
    switch signature {
    case "y":
      return "{ () -> UInt8?     in if case .byte(let v)      = \(src) { return v }; return nil }()"
    case "b":
      return "{ () -> Bool?      in if case .boolean(let v)   = \(src) { return v }; return nil }()"
    case "n":
      return "{ () -> Int16?     in if case .int16(let v)     = \(src) { return v }; return nil }()"
    case "q":
      return "{ () -> UInt16?    in if case .uint16(let v)    = \(src) { return v }; return nil }()"
    case "i":
      return "{ () -> Int32?     in if case .int32(let v)     = \(src) { return v }; return nil }()"
    case "u":
      return "{ () -> UInt32?    in if case .uint32(let v)    = \(src) { return v }; return nil }()"
    case "x":
      return "{ () -> Int64?     in if case .int64(let v)     = \(src) { return v }; return nil }()"
    case "t":
      return "{ () -> UInt64?    in if case .uint64(let v)    = \(src) { return v }; return nil }()"
    case "d":
      return "{ () -> Double?    in if case .double(let v)    = \(src) { return v }; return nil }()"
    case "s":
      return "{ () -> String?    in if case .string(let v)    = \(src) { return v }; return nil }()"
    case "o":
      return
        "{ () -> String?    in if case .objectPath(let v) = \(src) { return v }; return nil }()"
    case "g":
      return "{ () -> String?    in if case .signature(let v) = \(src) { return v }; return nil }()"
    case "h":
      return "{ () -> UInt32?    in if case .unixFd(let v)    = \(src) { return v }; return nil }()"
    case "v":
      return "{ () -> DBusVariant? in if case .variant(let v) = \(src) { return v }; return nil }()"
    case "ay":
      return
        "{ () -> [UInt8]?  in guard case .array(let _a) = \(src) else { return nil }; return _a.compactMap { if case .byte(let b) = $0 { return b }; return nil } }()"
    case "as":
      return
        "{ () -> [String]? in guard case .array(let _a) = \(src) else { return nil }; return _a.compactMap { if case .string(let s) = $0 { return s }; return nil } }()"
    default: return "Optional(\(src))"
    }
  }
}
