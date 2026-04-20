import Testing
@testable import DBusCodegen

@Suite
struct ParserTests {
  static let simpleXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <node>
      <interface name="org.example.Greeter">
        <method name="SayHello">
          <arg name="name" type="s" direction="in"/>
          <arg name="message" type="s" direction="out"/>
        </method>
        <property name="Greeting" type="s" access="read"/>
        <signal name="HelloSent">
          <arg name="recipient" type="s"/>
        </signal>
      </interface>
    </node>
    """

  @Test func parsesInterfaceName() throws {
    let node = try DBusParser.parse(xml: ParserTests.simpleXML)
    #expect(node.interfaces.count == 1)
    #expect(node.interfaces[0].name == "org.example.Greeter")
  }

  @Test func parsesMethod() throws {
    let node = try DBusParser.parse(xml: ParserTests.simpleXML)
    let method = try #require(node.interfaces[0].methods.first)
    #expect(method.name == "SayHello")
    #expect(method.inArgs.count == 1)
    #expect(method.outArgs.count == 1)
    #expect(method.inArgs[0].name == "name")
    #expect(method.inArgs[0].type == "s")
    #expect(method.outArgs[0].name == "message")
  }

  @Test func parsesProperty() throws {
    let node = try DBusParser.parse(xml: ParserTests.simpleXML)
    let prop = try #require(node.interfaces[0].properties.first)
    #expect(prop.name == "Greeting")
    #expect(prop.type == "s")
    #expect(prop.access == DBusProperty.Access.read)
  }

  @Test func parsesSignal() throws {
    let node = try DBusParser.parse(xml: ParserTests.simpleXML)
    let signal = try #require(node.interfaces[0].signals.first)
    #expect(signal.name == "HelloSent")
    #expect(signal.args.count == 1)
    #expect(signal.args[0].name == "recipient")
  }

  @Test func parsesMultipleInterfaces() throws {
    let xml = """
      <node>
        <interface name="org.example.A">
          <method name="Foo"/>
        </interface>
        <interface name="org.example.B">
          <property name="Bar" type="i" access="readwrite"/>
        </interface>
      </node>
      """
    let node = try DBusParser.parse(xml: xml)
    #expect(node.interfaces.count == 2)
    #expect(node.interfaces[0].name == "org.example.A")
    #expect(node.interfaces[1].name == "org.example.B")
    #expect(node.interfaces[1].properties[0].access == .readWrite)
  }

  @Test func parsesMethodWithNoArgs() throws {
    let xml = """
      <node>
        <interface name="org.example.Foo">
          <method name="NoArgs"/>
        </interface>
      </node>
      """
    let node = try DBusParser.parse(xml: xml)
    let method = try #require(node.interfaces[0].methods.first)
    #expect(method.name == "NoArgs")
    #expect(method.inArgs.isEmpty)
    #expect(method.outArgs.isEmpty)
  }

  @Test func throwsOnInvalidXML() {
    #expect(throws: (any Error).self) {
      try DBusParser.parse(xml: "not xml at all <<<")
    }
  }
}
