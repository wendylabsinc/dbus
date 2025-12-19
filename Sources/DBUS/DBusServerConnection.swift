/// Minimal connection API used by the object server. This is implemented by
/// ``DBusClient.Connection`` and can be mocked in tests.
public protocol DBusServerConnection: Sendable {
  func send(_ request: DBusRequest) async throws -> DBusMessage?
  func setMessageHandler(_ handler: @escaping @Sendable (DBusMessage) async -> Void) async
}

@available(macOS 10.15, iOS 13, *)
extension DBusClient.Connection: DBusServerConnection {}
