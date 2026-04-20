import Testing
@testable import DBusCodegen

@Suite
struct SignalGeneratorTests {
  static let iface = DBusInterface(
    name: "org.bluez.GattCharacteristic1",
    methods: [],
    properties: [],
    signals: [
      DBusSignal(
        name: "PropertiesChanged",
        args: [
          DBusArg(name: "interface_name", type: "s"),
          DBusArg(name: "changed_properties", type: "a{sv}"),
        ]
      ),
      DBusSignal(name: "Pinged", args: []),
    ]
  )

  @Test func generatesSignalMethodInProtocol() {
    var w = CodeWriter()
    SignalGenerator.generateProtocolMembers(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("func propertiesChanged() async throws -> AsyncStream"))
  }

  @Test func generatesNoArgSignalMethod() {
    var w = CodeWriter()
    SignalGenerator.generateProtocolMembers(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("func pinged() async throws -> AsyncStream<Void>"))
  }

  @Test func generatesSignalImplementation() {
    var w = CodeWriter()
    SignalGenerator.generateProxyImplementations(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("AddMatch"))
    #expect(code.contains("subscribeToSignal(interface:"))
    #expect(code.contains("PropertiesChanged"))
  }

  @Test func generatesNamedTupleStreamForMultiArgSignal() {
    var w = CodeWriter()
    SignalGenerator.generateProxyImplementations(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("interfaceName:"))
    #expect(code.contains("changedProperties:"))
  }
}
