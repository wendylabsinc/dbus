import Testing
@testable import DBusCodegen

@Suite
struct ServerGeneratorTests {
  static let iface = DBusInterface(
    name: "org.example.Greeter",
    methods: [
      DBusMethod(
        name: "SayHello",
        inArgs: [DBusArg(name: "name", type: "s")],
        outArgs: [DBusArg(name: "message", type: "s")]
      ),
    ],
    properties: [
      DBusProperty(name: "Greeting", type: "s", access: .read),
    ],
    signals: []
  )

  @Test func generatesHandlerProtocol() {
    var w = CodeWriter()
    ServerGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("public protocol OrgExampleGreeterHandler: Sendable"))
  }

  @Test func generatesMethodInHandler() {
    var w = CodeWriter()
    ServerGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("func sayHello(name: String) async throws -> String"))
  }

  @Test func generatesPropertyInHandler() {
    var w = CodeWriter()
    ServerGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("var greeting: String { get async throws }"))
  }

  @Test func generatesMakeInterfaceExtension() {
    var w = CodeWriter()
    ServerGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("extension OrgExampleGreeterHandler"))
    #expect(code.contains("func makeInterface() -> DBusObjectServer.Interface"))
  }

  @Test func makeInterfaceContainsMethodBridge() {
    var w = CodeWriter()
    ServerGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("\"SayHello\""))
    #expect(code.contains("org.example.Greeter"))
  }

  @Test func makeInterfaceDecodesArgs() {
    var w = CodeWriter()
    ServerGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains("guard case .string"))
    #expect(code.contains("ctx.arguments[0]"))
  }

  @Test func makeInterfaceEncodesReturnValue() {
    var w = CodeWriter()
    ServerGenerator.generate(interface: Self.iface, into: &w)
    let code = w.result
    #expect(code.contains(".string("))
  }
}
