import Testing
@testable import DBusCodegen

@Suite
struct IRTests {
  @Test func dbusArgStoresNameAndType() {
    let arg = DBusArg(name: "value", type: "ay")
    #expect(arg.name == "value")
    #expect(arg.type == "ay")
  }

  @Test func dbusMethodHasInAndOutArgs() {
    let inArg = DBusArg(name: "options", type: "a{sv}")
    let outArg = DBusArg(name: "value", type: "ay")
    let method = DBusMethod(name: "ReadValue", inArgs: [inArg], outArgs: [outArg])
    #expect(method.name == "ReadValue")
    #expect(method.inArgs.count == 1)
    #expect(method.outArgs.count == 1)
  }

  @Test func dbusPropertyAccess() {
    let prop = DBusProperty(name: "UUID", type: "s", access: .read)
    #expect(prop.name == "UUID")
    #expect(prop.access == .read)
    let rw = DBusProperty(name: "Value", type: "ay", access: .readWrite)
    #expect(rw.access == .readWrite)
  }

  @Test func dbusSignalHasArgs() {
    let arg = DBusArg(name: "interface_name", type: "s")
    let signal = DBusSignal(name: "PropertiesChanged", args: [arg])
    #expect(signal.name == "PropertiesChanged")
    #expect(signal.args.count == 1)
  }

  @Test func dbusInterfaceContainsAll() {
    let iface = DBusInterface(
      name: "org.example.Foo",
      methods: [DBusMethod(name: "Bar", inArgs: [], outArgs: [])],
      properties: [DBusProperty(name: "Baz", type: "s", access: .read)],
      signals: [DBusSignal(name: "Qux", args: [])]
    )
    #expect(iface.name == "org.example.Foo")
    #expect(iface.methods.count == 1)
    #expect(iface.properties.count == 1)
    #expect(iface.signals.count == 1)
  }

  @Test func dbusNodeContainsInterfaces() {
    let node = DBusNode(interfaces: [
      DBusInterface(name: "org.example.A", methods: [], properties: [], signals: []),
      DBusInterface(name: "org.example.B", methods: [], properties: [], signals: []),
    ])
    #expect(node.interfaces.count == 2)
  }
}
