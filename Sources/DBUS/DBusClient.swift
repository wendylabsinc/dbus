import Logging
import NIO
import NIOCore
import NIOExtras

/// A client for communicating with D-Bus services.
///
/// `DBusClient` provides an asynchronous interface for connecting to and communicating with D-Bus services.
/// It handles the underlying connection management, authentication, and message encoding/decoding.
///
/// ## Overview
/// The client uses Swift's async/await pattern for all operations, making it easy to integrate with modern Swift code.
/// Messages are sent and received using the ``DBusMessage`` type.
///
/// ## Example
/// ```swift
/// let address = try SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket")
/// let result = try await DBusClient.withConnection(to: address, auth: .anonymous) { replies, send in
///     let message = DBusMessage.createMethodCall(
///         destination: "org.freedesktop.DBus",
///         path: "/org/freedesktop/DBus",
///         interface: "org.freedesktop.DBus",
///         method: "ListNames",
///         serial: 1
///     )
///     try await send(message)
///
///     if let reply = try await replies.next() {
///         // Process the reply
///         return reply
///     }
///     throw DBusError.noReply
/// }
/// ```
@available(macOS 10.15, iOS 13, *)
public actor DBusClient: Sendable {
  private let group: EventLoopGroup
  private let asyncChannel: NIOAsyncChannel<DBusMessage, DBusMessage>

  internal init(group: EventLoopGroup, asyncChannel: NIOAsyncChannel<DBusMessage, DBusMessage>) {
    self.group = group
    self.asyncChannel = asyncChannel
  }

  public actor Connection: Sendable {
    public private(set) var send: Send
    let logger: Logger
    private var continuations = [(UInt32, CheckedContinuation<DBusMessage, Error>)]()
    private var messageHandler: (@Sendable (DBusMessage) async -> Void)?

    internal init(send: Send, logger: Logger) {
      self.send = send
      self.logger = logger
    }

    deinit {
      for (_, continuation) in continuations {
        continuation.resume(throwing: CancellationError())
      }
    }

    internal func run(replies: inout Replies) async throws {
      while let message = try await replies.next() {
        logger.trace(
          "Received message from DBUS",
          metadata: [
            "replyTo": "\(String(describing: message.replyTo))"
          ])
        if let (_, continuation) = continuations.first(where: { $0.0 == message.replyTo }) {
          continuations.removeAll(where: { $0.0 == message.replyTo })
          continuation.resume(returning: message)
        } else if let replyTo = message.replyTo {
          logger.warning(
            "Received message with unknown reply-to",
            metadata: [
              "reply-to": "\(String(describing: replyTo))"
            ])
        } else if let handler = messageHandler {
          await handler(message)
        }
      }
    }

    public func send(_ request: DBusRequest) async throws -> DBusMessage? {
      let requestId = try await send.send(request)

      if request.flags.contains(.noReplyExpected) {
        logger.trace(
          "Send request that does not expect a reply",
          metadata: [
            "serial": "\(requestId)"
          ])
        return nil
      }

      logger.trace(
        "Send request that expects a reply",
        metadata: [
          "serial": "\(requestId)"
        ])
      return try await withCheckedThrowingContinuation { continuation in
        continuations.append((requestId, continuation))
      }
    }

    /// Registers a handler for inbound messages that are not replies to sent requests.
    ///
    /// Useful for implementing server-side object export where the process needs to
    /// respond to incoming method calls.
    ///
    /// - Parameter handler: Async closure invoked for each unhandled inbound message.
    public func setMessageHandler(
      _ handler: @escaping @Sendable (DBusMessage) async -> Void
    ) async {
      messageHandler = handler
    }
  }

  /// A type for receiving reply messages from the D-Bus connection.
  ///
  /// `Replies` provides an async sequence interface for reading incoming messages.
  /// Messages are delivered in the order they are received from the bus.
  public struct Replies: @unchecked Sendable {
    fileprivate var iterator: NIOAsyncChannelInboundStream<DBusMessage>.AsyncIterator

    internal init(iterator: NIOAsyncChannelInboundStream<DBusMessage>.AsyncIterator) {
      self.iterator = iterator
    }

    /// Retrieves the next message from the D-Bus connection.
    ///
    /// This method suspends until a message is available or the connection is closed.
    ///
    /// - Returns: The next ``DBusMessage`` if available, or `nil` if the connection is closed.
    /// - Throws: An error if the connection fails or is interrupted.
    public mutating func next() async throws -> DBusMessage? {
      try await iterator.next()
    }
  }

  /// A type for sending messages to the D-Bus connection.
  ///
  /// `Send` provides methods for transmitting messages to the bus.
  /// All send operations are asynchronous and will complete when the message has been written to the connection.
  public actor Send {
    public private(set) var serial: UInt32 = 0
    fileprivate let writer: NIOAsyncChannelOutboundWriter<DBusMessage>

    internal init(writer: NIOAsyncChannelOutboundWriter<DBusMessage>) {
      self.writer = writer
    }

    public func send(_ request: DBusRequest) async throws -> UInt32 {
      serial &+= 1
      let message = DBusMessage(
        byteOrder: request.byteOrder,
        messageType: request.messageType,
        flags: request.flags,
        protocolVersion: request.protocolVersion,
        serial: serial,
        headerFields: request.headerFields,
        body: request.body
      )
      try await writer.write(message)
      return message.serial
    }

    public func callAsFunction(_ request: DBusRequest) async throws -> UInt32 {
      return try await send(request)
    }

    /// Sends a message through the D-Bus connection.
    ///
    /// - Parameter message: The ``DBusMessage`` to send.
    /// - Throws: An error if the send operation fails.
    public func send(_ message: DBusMessage) async throws {
      try await writer.write(message)
    }

    /// Sends a message through the D-Bus connection using function call syntax.
    ///
    /// This method provides a convenient way to send messages using function call syntax:
    /// ```swift
    /// try await send(message)
    /// ```
    ///
    /// - Parameter message: The ``DBusMessage`` to send.
    /// - Throws: An error if the send operation fails.
    public func callAsFunction(_ request: DBusMessage) async throws {
      try await send(request)
    }
  }

  /// Creates a connection to a D-Bus service and executes a handler with the connection.
  ///
  /// This method establishes a connection to the specified D-Bus address, performs authentication,
  /// and then executes the provided handler. The connection is automatically closed when the handler completes.
  ///
  /// - Parameters:
  ///   - address: The socket address of the D-Bus service to connect to.
  ///   - auth: The authentication type to use for the connection (e.g., `.anonymous` or `.external(userID:)`).
  ///   - logger: The logger to use for D-Bus operations. Defaults to a logger with label "dbus.client".
  ///   - handler: An async closure that receives ``Replies`` and ``Send`` instances for communicating with the bus.
  ///             The handler should return a value of type `R`.
  ///
  /// - Returns: The value returned by the handler.
  /// - Throws: An error if the connection fails, authentication fails, or the handler throws.
  ///
  /// ## Example
  /// ```swift
  /// let names = try await DBusClient.withConnection(to: address, auth: .anonymous) { replies, send in
  ///     // Send a message
  ///     try await send(listNamesMessage)
  ///
  ///     // Wait for reply
  ///     guard let reply = try await replies.next() else {
  ///         throw DBusError.noReply
  ///     }
  ///
  ///     return reply.body
  /// }
  /// ```
  public static func withConnection<R: Sendable>(
    to address: SocketAddress,
    auth: AuthType,
    logger: Logger = Logger(label: "dbus.client"),
    _ handler: @Sendable @escaping (Connection) async throws -> R
  ) async throws -> R {
    return try await withConnectionPair(to: address, auth: auth, logger: logger) { replies, send in
      let connection = Connection(send: send, logger: logger)
      async let _ = connection.run(replies: &replies)

      guard
        let helloReply = try await connection.send(
          .createMethodCall(
            destination: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus",
            method: "Hello"
          )),
        case .methodReturn = helloReply.messageType
      else {
        throw DBusError.missingReply
      }

      return try await handler(connection)
    }
  }

  /// Creates a connection to a D-Bus service and executes a handler with the connection.
  ///
  /// This method establishes a connection to the specified D-Bus address, performs authentication,
  /// and then executes the provided handler. The connection is automatically closed when the handler completes.
  ///
  /// - Parameters:
  ///   - address: The socket address of the D-Bus service to connect to.
  ///   - auth: The authentication type to use for the connection (e.g., `.anonymous` or `.external(userID:)`).
  ///   - logger: The logger to use for D-Bus operations. Defaults to a logger with label "dbus.client".
  ///   - handler: An async closure that receives ``Replies`` and ``Send`` instances for communicating with the bus.
  ///             The handler should return a value of type `R`.
  ///
  /// - Returns: The value returned by the handler.
  /// - Throws: An error if the connection fails, authentication fails, or the handler throws.
  ///
  /// ## Example
  /// ```swift
  /// let names = try await DBusClient.withConnection(to: address, auth: .anonymous) { replies, send in
  ///     // Send a message
  ///     try await send(listNamesMessage)
  ///
  ///     // Wait for reply
  ///     guard let reply = try await replies.next() else {
  ///         throw DBusError.noReply
  ///     }
  ///
  ///     return reply.body
  /// }
  /// ```
  public static func withConnectionPair<R: Sendable>(
    to address: SocketAddress,
    auth: AuthType,
    logger: Logger = Logger(label: "dbus.client"),
    _ handler: @Sendable @escaping (inout Replies, inout Send) async throws -> R
  ) async throws -> R {
    let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .channelInitializer { channel in
        do {
          try DBusClient.addToPipeline(channel.pipeline, auth: auth, logger: logger)
          return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }
    let asyncChannel = try await bootstrap.connect(to: address)
      .flatMapThrowing {
        try NIOAsyncChannel(
          wrappingChannelSynchronously: $0,
          configuration: .init(
            inboundType: DBusMessage.self,
            outboundType: DBusMessage.self
          )
        )
      }.get()

    return try await asyncChannel.executeThenClose { inbound, outbound in
      var replies = Replies(
        iterator: inbound.makeAsyncIterator()
      )
      var send = Send(writer: outbound)
      return try await handler(&replies, &send)
    }
  }

  static func addToPipeline(
    _ pipeline: ChannelPipeline, auth: AuthType, logger: Logger = Logger(label: "dbus.client")
  ) throws {
    let handlers: [any ChannelHandler] = [
      ByteToMessageHandler(LineBasedFrameDecoder()),
      DBusAuthenticationHandler(auth: auth, logger: logger),
      ByteToMessageHandler(DBusMessageDecoder(logger: logger)),
      MessageToByteHandler(DBusMessageEncoder(logger: logger)),
    ]
    try pipeline.syncOperations.addHandlers(handlers)
  }
}

internal enum DBusClientError: Error {
  case notConnected
}
