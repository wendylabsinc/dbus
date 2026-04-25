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
      let name = attributes["name"] ?? "arg"
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
      if let method = currentMethod {
        currentInterface?.methods.append(method)
        currentMethod = nil
      }
    case "signal":
      if let signal = currentSignal {
        currentInterface?.signals.append(signal)
        currentSignal = nil
      }
    case "interface":
      if let iface = currentInterface {
        node.interfaces.append(iface)
        currentInterface = nil
      }
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
    error = parseError
  }
}
