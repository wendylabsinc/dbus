import Foundation
#if canImport(FoundationXML)
  import FoundationXML
#endif

public enum DBusParserError: Error {
  case invalidXML(String)
}

public enum DBusParser {
  public static func parse(xml: String) throws -> DBusNode {
    guard let data = xml.data(using: .utf8) else {
      throw DBusParserError.invalidXML("Could not encode XML as UTF-8")
    }
    let delegate = ParserDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else {
      let desc = parser.parserError?.localizedDescription ?? "unknown error"
      throw DBusParserError.invalidXML(desc)
    }
    if let error = delegate.error { throw error }
    return delegate.node
  }
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
  var node = DBusNode(interfaces: [])
  var error: Error?

  private var currentInterface: DBusInterface?
  private var currentMethod: DBusMethod?
  private var currentSignal: DBusSignal?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?,
    attributes: [String: String]
  ) {
    switch elementName {
    case "interface":
      guard let name = attributes["name"] else { return }
      currentInterface = DBusInterface(name: name, methods: [], properties: [], signals: [])
    case "method":
      guard let name = attributes["name"] else { return }
      currentMethod = DBusMethod(name: name, inArgs: [], outArgs: [])
    case "signal":
      guard let name = attributes["name"] else { return }
      currentSignal = DBusSignal(name: name, args: [])
    case "arg":
      guard let type = attributes["type"] else { return }
      let name = attributes["name"] ?? ""
      let direction = attributes["direction"] ?? "in"
      let arg = DBusArg(name: name, type: type)
      if var method = currentMethod {
        if direction == "out" { method.outArgs.append(arg) } else { method.inArgs.append(arg) }
        currentMethod = method
      } else if var signal = currentSignal {
        signal.args.append(arg)
        currentSignal = signal
      }
    case "property":
      guard let name = attributes["name"], let type = attributes["type"] else { return }
      let accessStr = attributes["access"] ?? "read"
      let access: DBusProperty.Access
      switch accessStr {
      case "write": access = .write
      case "readwrite": access = .readWrite
      default: access = .read
      }
      currentInterface?.properties.append(DBusProperty(name: name, type: type, access: access))
    default:
      break
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?
  ) {
    switch elementName {
    case "method":
      if var method = currentMethod.take() {
        setFallbackNames(&method.inArgs)
        setFallbackNames(&method.outArgs)
        currentInterface?.methods.append(method)
      }
    case "signal":
      if var signal = currentSignal.take() {
        setFallbackNames(&signal.args)
        currentInterface?.signals.append(signal)
      }
    case "interface":
      if let iface = currentInterface.take() {
        node.interfaces.append(iface)
      }
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
    error = parseError
  }
}

extension ParserDelegate {
  private func setFallbackNames(_ args: inout [DBusArg]) {
    var used = Set<String>()
    var counter = 0

    for i in args.indices {
      if args[i].name.isEmpty {
        var candidate: String
        repeat {
          candidate = "arg\(counter)"
          counter += 1
        } while used.contains(TypeMapper.swiftIdentifier(candidate))

        args[i].name = candidate
      }

      used.insert(TypeMapper.swiftIdentifier(args[i].name))
    }
  }
}
