import Logging
import NIO
import NIOCore
import NIOExtras

#if canImport(FoundationEssentials)
  import FoundationEssentials
#elseif canImport(Foundation)
  import Foundation
#endif

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
    private var continuations: [UInt32: AsyncThrowingStream<DBusMessage, Error>.Continuation] = [:]
    private var messageHandler: (@Sendable (DBusMessage) async -> Void)?
    private var signalSubscribers:
      [(
        id: UInt64,
        interface: String,
        member: String,
        continuation: AsyncStream<DBusMessage>.Continuation
      )] = []
    private var nextSignalSubscriberId: UInt64 = 0

    internal init(send: Send, logger: Logger) {
      self.send = send
      self.logger = logger
    }

    deinit {
      for continuation in continuations.values {
        continuation.finish(throwing: CancellationError())
      }
      for subscriber in signalSubscribers {
        subscriber.continuation.finish()
      }
    }

    internal func run(replies: inout Replies) async throws {
      logger.trace("Connection.run() starting message loop")
      while let message = try await replies.next() {
        logger.trace(
          "Connection.run() received message from D-Bus",
          metadata: [
            "messageType": "\(message.messageType)",
            "serial": "\(message.serial)",
            "replyTo": "\(String(describing: message.replyTo))",
            "path": "\(message.path ?? "nil")",
            "interface": "\(message.interface ?? "nil")",
            "member": "\(message.member ?? "nil")",
          ])
        if let replyTo = message.replyTo,
          let continuation = continuations.removeValue(forKey: replyTo)
        {
          logger.trace(
            "Dispatching reply to waiting continuation", metadata: ["replyTo": "\(replyTo)"])
          continuation.yield(message)
          continuation.finish()
        } else if let replyTo = message.replyTo {
          logger.warning(
            "Received message with unknown reply-to",
            metadata: [
              "reply-to": "\(String(describing: replyTo))"
            ])
        } else if case .signal = message.messageType {
          let matchInterface = message.interface ?? ""
          let matchMember = message.member ?? ""
          var delivered = false
          for subscriber in signalSubscribers
          where subscriber.interface == matchInterface && subscriber.member == matchMember {
            subscriber.continuation.yield(message)
            delivered = true
          }
          if !delivered {
            if let handler = messageHandler {
              logger.trace("Forwarding unmatched signal to message handler")
              await handler(message)
            } else {
              logger.debug(
                "Received unhandled signal",
                metadata: ["interface": "\(matchInterface)", "member": "\(matchMember)"])
            }
          }
        } else if let handler = messageHandler {
          logger.trace(
            "Dispatching message to handler (no replyTo)",
            metadata: ["messageType": "\(message.messageType)"])
          await handler(message)
          logger.trace("Handler completed for message", metadata: ["serial": "\(message.serial)"])
        } else {
          logger.warning(
            "No handler set for message without replyTo",
            metadata: [
              "messageType": "\(message.messageType)",
              "path": "\(message.path ?? "nil")",
              "member": "\(message.member ?? "nil")",
            ])
        }
      }
      logger.trace("Connection.run() message loop exited (replies.next() returned nil)")
    }

    public func send(_ request: DBusRequest) async throws -> DBusMessage? {
      try await send(request, timeoutNanoseconds: nil)
    }

    public func send(_ request: DBusRequest, timeoutNanoseconds: UInt64?) async throws
      -> DBusMessage?
    {
      let requestId = await send.reserveSerial()
      let message = DBusMessage(
        byteOrder: request.byteOrder,
        messageType: request.messageType,
        flags: request.flags,
        protocolVersion: request.protocolVersion,
        serial: requestId,
        headerFields: request.headerFields,
        body: request.body,
        unixFds: request.unixFds
      )

      if request.flags.contains(.noReplyExpected) {
        logger.trace(
          "Send request that does not expect a reply",
          metadata: [
            "serial": "\(requestId)"
          ])
        try await send.send(message)
        return nil
      }

      logger.trace(
        "Send request that expects a reply",
        metadata: [
          "serial": "\(requestId)"
        ])
      var replyContinuation: AsyncThrowingStream<DBusMessage, Error>.Continuation!
      let replyStream = AsyncThrowingStream<DBusMessage, Error> { continuation in
        replyContinuation = continuation
      }
      continuations[requestId] = replyContinuation
      do {
        try await send.send(message)
      } catch {
        continuations.removeValue(forKey: requestId)?.finish(throwing: error)
        throw error
      }

      let iterator = ReplyIteratorBox(iterator: replyStream.makeAsyncIterator())
      do {
        let reply = try await Self.awaitReply(
          timeoutNanoseconds: timeoutNanoseconds,
          iterator: iterator
        )
        return reply
      } catch {
        continuations.removeValue(forKey: requestId)?.finish(throwing: error)
        throw error
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

    public func subscribeToSignal(
      interface: String,
      member: String
    ) -> AsyncStream<DBusMessage> {
      let id = nextSignalSubscriberId
      nextSignalSubscriberId += 1
      var storedContinuation: AsyncStream<DBusMessage>.Continuation!
      let stream = AsyncStream<DBusMessage> { continuation in
        storedContinuation = continuation
      }
      signalSubscribers.append(
        (id: id, interface: interface, member: member, continuation: storedContinuation))
      storedContinuation.onTermination = { [weak self] _ in
        Task { [weak self] in await self?.removeSignalSubscriber(id: id) }
      }
      return stream
    }

    private func removeSignalSubscriber(id: UInt64) {
      signalSubscribers.removeAll { $0.id == id }
    }

    private final class ReplyIteratorBox: @unchecked Sendable {
      private var iterator: AsyncThrowingStream<DBusMessage, Error>.AsyncIterator

      init(iterator: AsyncThrowingStream<DBusMessage, Error>.AsyncIterator) {
        self.iterator = iterator
      }

      func next() async throws -> DBusMessage? {
        try await iterator.next()
      }
    }

    private static func awaitReply(
      timeoutNanoseconds: UInt64?,
      iterator: ReplyIteratorBox
    ) async throws -> DBusMessage {
      if let timeoutNanoseconds {
        let reply = try await withTimeout(timeoutNanoseconds) {
          try await iterator.next()
        }
        guard let reply else {
          throw DBusError.missingReply
        }
        return reply
      }
      guard let reply = try await iterator.next() else {
        throw DBusError.missingReply
      }
      return reply
    }

    private static func withTimeout<T: Sendable>(
      _ nanoseconds: UInt64,
      operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
      try await withThrowingTaskGroup(of: T.self) { group in
        defer { group.cancelAll() }
        group.addTask {
          try await operation()
        }
        group.addTask {
          try await Task.sleep(nanoseconds: nanoseconds)
          throw DBusError.timeout
        }
        guard let result = try await group.next() else {
          throw DBusError.timeout
        }
        return result
      }
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

    public func reserveSerial() -> UInt32 {
      serial = DBusSerialGenerator.next(after: serial)
      return serial
    }

    public func send(_ request: DBusRequest) async throws -> UInt32 {
      let serial = reserveSerial()
      let message = DBusMessage(
        byteOrder: request.byteOrder,
        messageType: request.messageType,
        flags: request.flags,
        protocolVersion: request.protocolVersion,
        serial: serial,
        headerFields: request.headerFields,
        body: request.body,
        unixFds: request.unixFds
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
    return try await withConnectionPair(
      to: address,
      auth: auth,
      logger: logger
    ) { replies, send in
      let connection = Connection(send: send, logger: logger)
      var replyLoop = replies
      let runTask = Task {
        try await connection.run(replies: &replyLoop)
      }
      defer { runTask.cancel() }

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
    let enableUnixFDs =
      switch address {
      case .unixDomainSocket: true
      case .v4, .v6: false
      }
    let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .channelInitializer { channel in
        do {
          try DBusClient.addToPipeline(
            channel.pipeline,
            auth: auth,
            enableUnixFDs: enableUnixFDs,
            logger: logger
          )
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

  public static func withConnection<R: Sendable>(
    to address: DBusAddress,
    auth: AuthType,
    logger: Logger = Logger(label: "dbus.client"),
    _ handler: @Sendable @escaping (Connection) async throws -> R
  ) async throws -> R {
    return try await withConnectionPair(
      to: address,
      auth: auth,
      logger: logger
    ) { replies, send in
      let connection = Connection(send: send, logger: logger)
      var replyLoop = replies
      let runTask = Task {
        try await connection.run(replies: &replyLoop)
      }
      defer { runTask.cancel() }

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

  public static func withConnectionPair<R: Sendable>(
    to address: DBusAddress,
    auth: AuthType,
    logger: Logger = Logger(label: "dbus.client"),
    _ handler: @Sendable @escaping (inout Replies, inout Send) async throws -> R
  ) async throws -> R {
    let initialBytes = try initialBytes(for: address)
    let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .channelInitializer { channel in
        do {
          let enableUnixFDs =
            switch address {
            case .unix, .unixAbstract: true
            case .tcp, .nonceTcp: false
            }
          try DBusClient.addToPipeline(
            channel.pipeline,
            auth: auth,
            enableUnixFDs: enableUnixFDs,
            initialBytes: initialBytes,
            logger: logger
          )
          return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }

    let channel = try await connect(bootstrap, to: address)
    let asyncChannel = try await channel.eventLoop.submit {
      try NIOAsyncChannel(
        wrappingChannelSynchronously: channel,
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

  public static func withConnection<R: Sendable>(
    to address: String,
    auth: AuthType,
    logger: Logger = Logger(label: "dbus.client"),
    _ handler: @Sendable @escaping (Connection) async throws -> R
  ) async throws -> R {
    let parsedAddress = try DBusAddress.parse(address)
    return try await withConnection(
      to: parsedAddress,
      auth: auth,
      logger: logger,
      handler
    )
  }

  public static func withConnectionPair<R: Sendable>(
    to address: String,
    auth: AuthType,
    logger: Logger = Logger(label: "dbus.client"),
    _ handler: @Sendable @escaping (inout Replies, inout Send) async throws -> R
  ) async throws -> R {
    let parsedAddress = try DBusAddress.parse(address)
    return try await withConnectionPair(
      to: parsedAddress,
      auth: auth,
      logger: logger,
      handler
    )
  }

  /// Connects to the session bus resolved from the environment.
  ///
  /// This is a convenience wrapper around ``DBusAddress/sessionBusAddress()``.
  public static func withSessionBus<R: Sendable>(
    auth: AuthType,
    logger: Logger = Logger(label: "dbus.client"),
    _ handler: @Sendable @escaping (Connection) async throws -> R
  ) async throws -> R {
    let address = try DBusAddress.sessionBusAddress()
    return try await withConnection(
      to: address,
      auth: auth,
      logger: logger,
      handler
    )
  }

  /// Connects to the system bus resolved from the environment.
  ///
  /// This is a convenience wrapper around ``DBusAddress/systemBusAddress()``.
  public static func withSystemBus<R: Sendable>(
    auth: AuthType,
    logger: Logger = Logger(label: "dbus.client"),
    _ handler: @Sendable @escaping (Connection) async throws -> R
  ) async throws -> R {
    let address = try DBusAddress.systemBusAddress()
    return try await withConnection(
      to: address,
      auth: auth,
      logger: logger,
      handler
    )
  }

  private static func connect(
    _ bootstrap: ClientBootstrap,
    to address: DBusAddress
  ) async throws -> Channel {
    switch address {
    case .unix, .unixAbstract:
      let socket = try address.unixSocketAddress()
      return try await bootstrap.connect(to: socket).get()
    case .tcp(let host, let port, let family),
      .nonceTcp(let host, let port, let family, _):
      return try await connectTcp(bootstrap, host: host, port: port, family: family)
    }
  }

  private static func connectTcp(
    _ bootstrap: ClientBootstrap,
    host: String,
    port: Int,
    family: DBusAddress.Family?
  ) async throws -> Channel {
    if let socket = try socketAddressIfLiteral(host: host, port: port, family: family) {
      return try await bootstrap.connect(to: socket).get()
    }
    return try await bootstrap.connect(host: host, port: port).get()
  }

  private static func socketAddressIfLiteral(
    host: String,
    port: Int,
    family: DBusAddress.Family?
  ) throws -> SocketAddress? {
    guard let socket = try? SocketAddress(ipAddress: host, port: port) else {
      return nil
    }
    if let family {
      let matches = matchesFamily(socket, family: family)
      guard matches else {
        throw DBusAddressError.invalidFamily
      }
    }
    return socket
  }

  private static func matchesFamily(_ socket: SocketAddress, family: DBusAddress.Family) -> Bool {
    switch (family, socket.protocol) {
    case (.ipv4, .inet), (.ipv6, .inet6):
      return true
    default:
      return false
    }
  }

  private static func initialBytes(for address: DBusAddress) throws -> [UInt8] {
    switch address {
    case .nonceTcp(_, _, _, let nonceFile):
      return try loadNonceBytes(from: nonceFile)
    case .unix, .unixAbstract, .tcp:
      return []
    }
  }

  private static func loadNonceBytes(from path: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw DBusAddressError.invalidNonceFile
    }
    guard data.count == 16 else {
      throw DBusAddressError.invalidNonceFile
    }
    return Array(data)
  }

  static func addToPipeline(
    _ pipeline: ChannelPipeline,
    auth: AuthType,
    enableUnixFDs: Bool,
    initialBytes: [UInt8] = [],
    logger: Logger = Logger(label: "dbus.client")
  ) throws {
    let handlers: [any ChannelHandler] = [
      DBusErrorLogger(logger: logger),  // Error logger at the front
      ByteToMessageHandler(LineBasedFrameDecoder()),
      DBusAuthenticationHandler(
        auth: auth,
        enableUnixFDs: enableUnixFDs,
        initialBytes: initialBytes,
        logger: logger
      ),
      ByteToMessageHandler(DBusMessageDecoder(logger: logger)),
      MessageToByteHandler(DBusMessageEncoder(logger: logger)),
    ]
    try pipeline.syncOperations.addHandlers(handlers)
  }
}

/// Handler to log errors and channel lifecycle events for debugging
internal final class DBusErrorLogger: ChannelDuplexHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private let logger: Logger

  init(logger: Logger) {
    self.logger = logger
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    context.fireChannelRead(data)
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    context.fireChannelReadComplete()
  }

  func channelInactive(context: ChannelHandlerContext) {
    logger.debug("Channel became inactive")
    context.fireChannelInactive()
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    context.write(data, promise: promise)
  }

  func flush(context: ChannelHandlerContext) {
    context.flush()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    logger.error(
      "Error caught in D-Bus channel pipeline",
      metadata: [
        "error": "\(error)",
        "errorType": "\(type(of: error))",
      ])
    context.fireErrorCaught(error)
  }

  func channelWritabilityChanged(context: ChannelHandlerContext) {
    context.fireChannelWritabilityChanged()
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    context.fireUserInboundEventTriggered(event)
  }
}

internal enum DBusClientError: Error {
  case notConnected
}
