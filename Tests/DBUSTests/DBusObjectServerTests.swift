import Logging
import Testing

@testable import DBUS

@Suite
struct DBusObjectServerTests {
  @Test
  func dispatchesMethodReturn() async throws {
    let conn = MockConnection()
    let logger = Logger(label: "dbus.test.server")
    let server = DBusObjectServer(connection: conn, logger: logger)

    var iface = DBusObjectServer.Interface(name: "org.test.Echo")
    iface.methods = [
      .init(name: "Ping") { _ in [.string("Pong")] }
    ]
    await server.export(.init(path: "/org/test/Echo", interfaces: [iface]))

    await conn.waitForHandler()

    let call = DBusMessage.createMethodCall(
      destination: "org.test",
      path: "/org/test/Echo",
      interface: "org.test.Echo",
      method: "Ping",
      serial: 1,
      body: []
    )

    await conn.emit(call)
    let sent = await conn.sentRequests()
    #expect(sent.count == 1)
    #expect(sent[0].messageType == .methodReturn)
    #expect(
      sent[0].headerFields.contains(where: {
        $0.code == .replySerial && $0.variant.value.uint32 == call.serial
      })
    )
    #expect(sent[0].body.first?.string == "Pong")
  }
}

actor MockConnection: DBusServerConnection {
  private var outbound: [DBusRequest] = []
  private var handler: (@Sendable (DBusMessage) async -> Void)?

  func send(_ request: DBusRequest) async throws -> DBusMessage? {
    outbound.append(request)
    return nil
  }

  func setMessageHandler(_ handler: @escaping @Sendable (DBusMessage) async -> Void) async {
    self.handler = handler
  }

  func emit(_ message: DBusMessage) async {
    guard let handler else { return }
    await handler(message)
  }

  func sentRequests() async -> [DBusRequest] {
    outbound
  }

  func waitForHandler() async {
    while handler == nil {
      await Task.yield()
    }
  }
}
