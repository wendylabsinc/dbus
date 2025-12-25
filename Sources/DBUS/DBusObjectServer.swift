import Logging

/// Server-side object export helper that dispatches incoming D-Bus method calls
/// to user-provided handlers and responds to property, introspection, and
/// object manager requests.
@available(macOS 10.15, iOS 13, *)
public actor DBusObjectServer: Sendable {
  // MARK: Public helper types

  public struct MethodArg: Sendable {
    public let name: String
    public let type: String

    public init(name: String, type: String) {
      self.name = name
      self.type = type
    }
  }

  public struct Method: Sendable {
    public let name: String
    public let inputArgs: [MethodArg]
    public let outputArgs: [MethodArg]
    public let handler: @Sendable (MethodCallContext) async throws -> [DBusValue]

    public init(
      name: String,
      inputArgs: [MethodArg] = [],
      outputArgs: [MethodArg] = [],
      handler: @escaping @Sendable (MethodCallContext) async throws -> [DBusValue]
    ) {
      self.name = name
      self.inputArgs = inputArgs
      self.outputArgs = outputArgs
      self.handler = handler
    }
  }

  public struct Property: Sendable {
    public enum Access: String, Sendable {
      case read = "read"
      case write = "write"
      case readWrite = "readwrite"
    }

    public let name: String
    public let signature: String
    public let access: Access
    private let getter: @Sendable (PropertyContext) async throws -> DBusValue
    private let setter: (@Sendable (DBusValue, PropertyContext) async throws -> Void)?

    public init(
      name: String,
      signature: String,
      access: Access = .read,
      get: @escaping @Sendable (PropertyContext) async throws -> DBusValue,
      set: (@Sendable (DBusValue, PropertyContext) async throws -> Void)? = nil
    ) {
      self.name = name
      self.signature = signature
      self.access = access
      self.getter = get
      self.setter = set
    }

    public init(
      name: String,
      value: DBusValue,
      access: Access = .read
    ) {
      self.init(
        name: name,
        signature: value.dbusTypeSignature,
        access: access,
        get: { _ in value },
        set: nil
      )
    }

    func get(context: PropertyContext) async throws -> DBusValue {
      try await getter(context)
    }

    func set(value: DBusValue, context: PropertyContext) async throws {
      guard let setter else { throw DBusServerError.propertyReadOnly(name) }
      guard access != .read else { throw DBusServerError.propertyReadOnly(name) }
      try await setter(value, context)
    }
  }

  public struct Signal: Sendable {
    public let name: String
    public let args: [MethodArg]

    public init(name: String, args: [MethodArg] = []) {
      self.name = name
      self.args = args
    }
  }

  public struct Interface: Sendable {
    public let name: String
    public var methods: [Method]
    public var properties: [Property]
    public var signals: [Signal]

    public init(
      name: String,
      methods: [Method] = [],
      properties: [Property] = [],
      signals: [Signal] = []
    ) {
      self.name = name
      self.methods = methods
      self.properties = properties
      self.signals = signals
    }
  }

  public struct ExportedObject: Sendable {
    public let path: String
    public var interfaces: [Interface]
    public var exposesObjectManager: Bool

    public init(
      path: String,
      interfaces: [Interface],
      exposesObjectManager: Bool = false
    ) {
      self.path = path
      self.interfaces = interfaces
      self.exposesObjectManager = exposesObjectManager
    }
  }

  public struct MethodCallContext: Sendable {
    public let message: DBusMessage
    public let connection: any DBusServerConnection
    public let path: String
    public let interface: String?
    public let member: String

    public var arguments: [DBusValue] { message.body }
    public var sender: String? { message.sender }
  }

  public struct PropertyContext: Sendable {
    public let message: DBusMessage
    public let connection: any DBusServerConnection
    public let path: String
    public let interface: String
    public var sender: String? { message.sender }
  }

  // MARK: Private state

  private var objects: [String: ExportedObject] = [:]
  private let connection: any DBusServerConnection
  private let logger: Logger

  public init(
    connection: any DBusServerConnection,
    logger: Logger = Logger(label: "dbus.server")
  ) {
    self.connection = connection
    self.logger = logger

    Task {
      await connection.setMessageHandler { [weak self] message in
        guard let self else { return }
        await self.handle(message: message)
      }
    }
  }

  /// Export an object path with interfaces.
  public func export(_ object: ExportedObject) {
    objects[object.path] = object
  }

  /// Remove a previously exported object path.
  public func unexport(path: String) {
    objects.removeValue(forKey: path)
  }

  // MARK: Dispatch

  private func handle(message: DBusMessage) async {
    guard message.messageType == .methodCall else { return }
    guard let path = message.path else { return }
    guard let object = objects[path] else {
      await sendError(.unknownObject, replyingTo: message)
      return
    }

    if message.interface == "org.freedesktop.DBus.Introspectable" || message.member == "Introspect"
    {
      await handleIntrospect(path: path, message: message)
      return
    }

    if message.interface == "org.freedesktop.DBus.Properties" {
      await handleProperties(message: message, object: object)
      return
    }

    if message.interface == "org.freedesktop.DBus.ObjectManager" {
      await handleObjectManager(for: path, message: message)
      return
    }

    guard let member = message.member else {
      await sendError(.unknownMethod, replyingTo: message)
      return
    }

    if let interfaceName = message.interface,
      let method = object.interfaces.first(where: { $0.name == interfaceName })?.methods.first(
        where: { $0.name == member })
    {
      await invoke(method: method, object: object, message: message)
      return
    }

    // Try a member match across interfaces when interface is omitted
    if message.interface == nil {
      let matches = object.interfaces.compactMap { iface in
        iface.methods.first(where: { $0.name == member }).map { (iface.name, $0) }
      }
      if matches.count == 1, let match = matches.first {
        await invoke(method: match.1, object: object, message: message, interfaceName: match.0)
        return
      }
    }

    await sendError(.unknownMethod, replyingTo: message)
  }

  private func invoke(
    method: Method,
    object: ExportedObject,
    message: DBusMessage,
    interfaceName: String? = nil
  ) async {
    guard let member = message.member else { return }
    do {
      let ctx = MethodCallContext(
        message: message,
        connection: connection,
        path: object.path,
        interface: interfaceName ?? message.interface,
        member: member
      )
      let replyValues = try await method.handler(ctx)
      guard !message.flags.contains(.noReplyExpected) else { return }
      _ = try await connection.send(
        DBusRequest.createMethodReturn(replyingTo: message, body: replyValues)
      )
    } catch {
      logger.debug("Method handler threw error", metadata: ["error": "\(error)"])
      await sendError(.failed(reason: "\(error)"), replyingTo: message)
    }
  }

  // MARK: Properties

  private func handleProperties(message: DBusMessage, object: ExportedObject) async {
    guard let member = message.member else {
      await sendError(.unknownMethod, replyingTo: message)
      return
    }

    switch member {
    case "Get":
      guard
        let iface = message.body.first?.string,
        let propName = message.body.dropFirst().first?.string,
        let prop = object.interfaces.first(where: { $0.name == iface })?.properties.first(
          where: { $0.name == propName })
      else {
        await sendError(.unknownProperty, replyingTo: message)
        return
      }

      do {
        let value = try await prop.get(
          context: PropertyContext(
            message: message, connection: connection, path: object.path, interface: iface))
        let variant = DBusVariant(signature: prop.signature, value: value)
        guard !message.flags.contains(.noReplyExpected) else { return }
        _ = try await connection.send(
          DBusRequest.createMethodReturn(replyingTo: message, body: [.variant(variant)])
        )
      } catch {
        await sendError(.failed(reason: "\(error)"), replyingTo: message)
      }

    case "GetAll":
      guard let iface = message.body.first?.string else {
        await sendError(.invalidArgs, replyingTo: message)
        return
      }
      guard let properties = object.interfaces.first(where: { $0.name == iface })?.properties else {
        await sendError(.unknownInterface, replyingTo: message)
        return
      }

      do {
        var values: [DBusValue: DBusValue] = [:]
        for property in properties {
          let value = try await property.get(
            context: PropertyContext(
              message: message, connection: connection, path: object.path, interface: iface))
          values[.string(property.name)] = .variant(
            DBusVariant(signature: property.signature, value: value)
          )
        }
        guard !message.flags.contains(.noReplyExpected) else { return }
        _ = try await connection.send(
          DBusRequest.createMethodReturn(replyingTo: message, body: [.dictionary(values)])
        )
      } catch {
        await sendError(.failed(reason: "\(error)"), replyingTo: message)
      }

    case "Set":
      guard
        let iface = message.body.first?.string,
        let propName = message.body.dropFirst().first?.string,
        case .variant(let newValueVariant)? = message.body.dropFirst(2).first,
        let prop = object.interfaces.first(where: { $0.name == iface })?.properties.first(
          where: { $0.name == propName })
      else {
        await sendError(.invalidArgs, replyingTo: message)
        return
      }

      do {
        try await prop.set(
          value: newValueVariant.value,
          context: PropertyContext(
            message: message, connection: connection, path: object.path, interface: iface)
        )
        guard !message.flags.contains(.noReplyExpected) else { return }
        _ = try await connection.send(DBusRequest.createMethodReturn(replyingTo: message, body: []))
      } catch {
        await sendError(.failed(reason: "\(error)"), replyingTo: message)
      }
    default:
      await sendError(.unknownMethod, replyingTo: message)
    }
  }

  // MARK: Introspection

  private func handleIntrospect(path: String, message: DBusMessage) async {
    let xml = buildIntrospectionXML(for: path)
    do {
      guard !message.flags.contains(.noReplyExpected) else { return }
      _ = try await connection.send(
        DBusRequest.createMethodReturn(replyingTo: message, body: [.string(xml)])
      )
    } catch {
      logger.debug("Failed to send introspection", metadata: ["error": "\(error)"])
    }
  }

  private func buildIntrospectionXML(for path: String) -> String {
    var lines: [String] = []
    lines.append(
      """
      <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
      <node>
      """
    )

    // Default Introspectable
    lines.append(
      """
        <interface name="org.freedesktop.DBus.Introspectable">
          <method name="Introspect">
            <arg name="data" type="s" direction="out"/>
          </method>
        </interface>
      """
    )

    if let object = objects[path], object.interfaces.contains(where: { !$0.properties.isEmpty }) {
      lines.append(
        """
          <interface name="org.freedesktop.DBus.Properties">
            <method name="Get">
              <arg name="interface" type="s" direction="in"/>
              <arg name="property" type="s" direction="in"/>
              <arg name="value" type="v" direction="out"/>
            </method>
            <method name="GetAll">
              <arg name="interface" type="s" direction="in"/>
              <arg name="properties" type="a{sv}" direction="out"/>
            </method>
            <method name="Set">
              <arg name="interface" type="s" direction="in"/>
              <arg name="property" type="s" direction="in"/>
              <arg name="value" type="v" direction="in"/>
            </method>
          </interface>
        """
      )
    }

    if let object = objects[path], object.exposesObjectManager {
      lines.append(
        """
          <interface name="org.freedesktop.DBus.ObjectManager">
            <method name="GetManagedObjects">
              <arg name="objects" type="a{oa{sa{sv}}}" direction="out"/>
            </method>
          </interface>
        """
      )
    }

    if let object = objects[path] {
      for iface in object.interfaces {
        lines.append("  <interface name=\"\(iface.name)\">")
        for method in iface.methods {
          lines.append("    <method name=\"\(method.name)\">")
          for arg in method.inputArgs {
            lines.append(
              "      <arg name=\"\(arg.name)\" type=\"\(arg.type)\" direction=\"in\"/>"
            )
          }
          for arg in method.outputArgs {
            lines.append(
              "      <arg name=\"\(arg.name)\" type=\"\(arg.type)\" direction=\"out\"/>"
            )
          }
          lines.append("    </method>")
        }

        for prop in iface.properties {
          lines.append(
            "    <property name=\"\(prop.name)\" type=\"\(prop.signature)\" access=\"\(prop.access.rawValue)\"/>"
          )
        }

        for signal in iface.signals {
          lines.append("    <signal name=\"\(signal.name)\">")
          for arg in signal.args {
            lines.append("      <arg name=\"\(arg.name)\" type=\"\(arg.type)\"/>")
          }
          lines.append("    </signal>")
        }
        lines.append("  </interface>")
      }
    }

    let childNames = objects.keys
      .filter { $0.hasPrefix(path == "/" ? "/" : path + "/") && $0 != path }
      .compactMap { childPath -> String? in
        let trimmed = childPath.dropFirst(path.count)
        guard let next = trimmed.split(separator: "/").first else { return nil }
        return String(next)
      }
    for child in Set(childNames) {
      lines.append("  <node name=\"\(child)\"/>")
    }

    lines.append("</node>")
    return lines.joined(separator: "\n")
  }

  // MARK: ObjectManager

  private func handleObjectManager(for basePath: String, message: DBusMessage) async {
    let managed = await managedObjects(basePath: basePath)
    do {
      guard !message.flags.contains(.noReplyExpected) else { return }
      _ = try await connection.send(
        DBusRequest.createMethodReturn(replyingTo: message, body: [.dictionary(managed)])
      )
    } catch {
      logger.debug("Failed to send GetManagedObjects", metadata: ["error": "\(error)"])
    }
  }

  private func managedObjects(basePath: String) async -> [DBusValue: DBusValue] {
    var result: [DBusValue: DBusValue] = [:]
    for (path, object) in objects where path == basePath || path.hasPrefix(basePath + "/") {
      var interfacesDict: [DBusValue: DBusValue] = [:]
      for iface in object.interfaces {
        var props: [DBusValue: DBusValue] = [:]
        for prop in iface.properties {
          let ctx = PropertyContext(
            message: DBusMessage(
              byteOrder: .host,
              messageType: .methodCall,
              flags: [],
              protocolVersion: 1,
              serial: 0,
              headerFields: [],
              body: []
            ),
            connection: connection,
            path: path,
            interface: iface.name
          )
          if let value = try? await prop.get(context: ctx) {
            props[.string(prop.name)] = .variant(
              DBusVariant(signature: prop.signature, value: value)
            )
          }
        }
        interfacesDict[.string(iface.name)] = .dictionary(props)
      }
      result[.objectPath(path)] = .dictionary(interfacesDict)
    }
    return result
  }

  // MARK: Error helpers

  private func sendError(_ error: DBusServerError, replyingTo message: DBusMessage) async {
    guard !message.flags.contains(.noReplyExpected) else { return }
    do {
      _ = try await connection.send(
        DBusRequest.createError(
          replyingTo: message, errorName: error.errorName, body: error.body)
      )
    } catch {
      logger.debug("Failed to send error reply", metadata: ["error": "\(error)"])
    }
  }
}

public enum DBusServerError: Error, Sendable {
  case unknownObject
  case unknownInterface
  case unknownMethod
  case unknownProperty
  case propertyReadOnly(String)
  case invalidArgs
  case failed(reason: String)

  var errorName: String {
    switch self {
    case .unknownObject: return "org.freedesktop.DBus.Error.UnknownObject"
    case .unknownInterface: return "org.freedesktop.DBus.Error.UnknownInterface"
    case .unknownMethod: return "org.freedesktop.DBus.Error.UnknownMethod"
    case .unknownProperty: return "org.freedesktop.DBus.Error.UnknownProperty"
    case .propertyReadOnly: return "org.freedesktop.DBus.Error.PropertyReadOnly"
    case .invalidArgs: return "org.freedesktop.DBus.Error.InvalidArgs"
    case .failed: return "org.freedesktop.DBus.Error.Failed"
    }
  }

  var body: [DBusValue] {
    switch self {
    case .propertyReadOnly(let name):
      return [.string("Property \(name) is read-only")]
    case .failed(let reason):
      return [.string(reason)]
    default:
      return []
    }
  }
}
