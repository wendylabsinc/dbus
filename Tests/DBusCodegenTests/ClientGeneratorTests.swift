import Testing
@testable import DBusCodegen

@Suite
struct ClientGeneratorTests {
  static let iface = DBusInterface(
    name: "org.example.Greeter",
    methods: [
      DBusMethod(
        name: "SayHello",
        inArgs: [DBusArg(name: "name", type: "s")],
        outArgs: [DBusArg(name: "message", type: "s")]
      ),
      DBusMethod(name: "Goodbye", inArgs: [], outArgs: []),
    ],
    properties: [
      DBusProperty(name: "Greeting", type: "s", access: .read),
      DBusProperty(name: "Count", type: "i", access: .readWrite),
    ],
    signals: []
  )

  @Test func generatesProtocolDeclaration() {
    var w = CodeWriter()
    ClientGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("public protocol OrgExampleGreeter"))
  }

  @Test func generatesProxyStruct() {
    var w = CodeWriter()
    ClientGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("public struct OrgExampleGreeterProxy: OrgExampleGreeter"))
  }

  @Test func generatesMethodInProtocol() {
    var w = CodeWriter()
    ClientGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("func sayHello(name: String) async throws -> String"))
  }

  @Test func generatesVoidMethodInProtocol() {
    var w = CodeWriter()
    ClientGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("func goodbye() async throws"))
  }

  @Test func generatesReadPropertyInProtocol() {
    var w = CodeWriter()
    ClientGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("var greeting: String { get async throws }"))
  }

  @Test func generatesWritablePropertyAsSetterInProtocol() {
    var w = CodeWriter()
    ClientGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("var count: Int32 { get async throws }"))
    #expect(code.contains("func setCount(_ newValue: Int32) async throws"))
  }

  @Test func generatesProxyInit() {
    var w = CodeWriter()
    ClientGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("public init(connection: DBusClient.Connection, destination: String, path: String)"))
  }

  @Test func generatesMethodImplementation() {
    var w = CodeWriter()
    ClientGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("DBusRequest.createMethodCall("))
    #expect(code.contains("interface: \"org.example.Greeter\""))
    #expect(code.contains("method: \"SayHello\""))
    #expect(code.contains(".string(name)"))
  }

  @Test func generatesPropertyGetterImplementation() {
    var w = CodeWriter()
    ClientGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("org.freedesktop.DBus.Properties"))
    #expect(code.contains("\"Greeting\""))
  }
}
