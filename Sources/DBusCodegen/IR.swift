public struct DBusArg: Sendable, Equatable {
  public var name: String
  public var type: String

  public init(name: String, type: String) {
    self.name = name
    self.type = type
  }
}

public struct DBusMethod: Sendable, Equatable {
  public var name: String
  public var inArgs: [DBusArg]
  public var outArgs: [DBusArg]

  public init(name: String, inArgs: [DBusArg], outArgs: [DBusArg]) {
    self.name = name
    self.inArgs = inArgs
    self.outArgs = outArgs
  }
}

public struct DBusProperty: Sendable, Equatable {
  public enum Access: String, Sendable, Equatable {
    case read
    case write
    case readWrite
  }

  public var name: String
  public var type: String
  public var access: Access

  public init(name: String, type: String, access: Access) {
    self.name = name
    self.type = type
    self.access = access
  }
}

public struct DBusSignal: Sendable, Equatable {
  public var name: String
  public var args: [DBusArg]

  public init(name: String, args: [DBusArg]) {
    self.name = name
    self.args = args
  }
}

public struct DBusInterface: Sendable, Equatable {
  public var name: String
  public var methods: [DBusMethod]
  public var properties: [DBusProperty]
  public var signals: [DBusSignal]

  public init(name: String, methods: [DBusMethod], properties: [DBusProperty], signals: [DBusSignal]) {
    self.name = name
    self.methods = methods
    self.properties = properties
    self.signals = signals
  }
}

public struct DBusNode: Sendable, Equatable {
  public var interfaces: [DBusInterface]

  public init(interfaces: [DBusInterface]) {
    self.interfaces = interfaces
  }
}
