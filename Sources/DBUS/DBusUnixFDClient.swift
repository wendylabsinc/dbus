import Dispatch
import Logging
import NIOCore

#if canImport(FoundationEssentials)
  import FoundationEssentials
#elseif canImport(Foundation)
  import Foundation
#endif

#if canImport(Glibc)
  import Glibc

  /// A D-Bus client that supports UNIX_FD passing (Linux only).
  ///
  /// Use this client when you need to send or receive file descriptors (`h` values).
  @available(macOS 10.15, iOS 13, *)
  public enum DBusUnixFDClient {
    private final class ContinuationBox: @unchecked Sendable {
      let continuation: AsyncThrowingStream<DBusMessage, Error>.Continuation

      init(_ continuation: AsyncThrowingStream<DBusMessage, Error>.Continuation) {
        self.continuation = continuation
      }
    }
    /// Async sequence wrapper for inbound messages.
    public struct Replies: @unchecked Sendable {
      fileprivate var iterator: AsyncThrowingStream<DBusMessage, Error>.AsyncIterator

      internal init(iterator: AsyncThrowingStream<DBusMessage, Error>.AsyncIterator) {
        self.iterator = iterator
      }

      public mutating func next() async throws -> DBusMessage? {
        try await iterator.next()
      }
    }

    /// Sends messages over an established D-Bus connection.
    public actor Send {
      public private(set) var serial: UInt32 = 0
      private let socket: UnixFDSocket
      private let unixFdsEnabled: Bool

      internal init(socket: UnixFDSocket, unixFdsEnabled: Bool) {
        self.socket = socket
        self.unixFdsEnabled = unixFdsEnabled
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
        try socket.sendMessage(message, unixFdsEnabled: unixFdsEnabled)
        return serial
      }

      public func callAsFunction(_ request: DBusRequest) async throws -> UInt32 {
        try await send(request)
      }

      public func send(_ message: DBusMessage) async throws {
        try socket.sendMessage(message, unixFdsEnabled: unixFdsEnabled)
      }

      public func callAsFunction(_ message: DBusMessage) async throws {
        try await send(message)
      }
    }

    /// Represents a live D-Bus connection with reply tracking.
    public actor Connection: Sendable {
      public private(set) var send: Send
      let logger: Logger
      private var continuations: [UInt32: AsyncThrowingStream<DBusMessage, Error>.Continuation] =
        [:]
      private var messageHandler: (@Sendable (DBusMessage) async -> Void)?

      internal init(send: Send, logger: Logger) {
        self.send = send
        self.logger = logger
      }

      deinit {
        for continuation in continuations.values {
          continuation.finish(throwing: CancellationError())
        }
      }

      internal func run(replies: inout Replies) async throws {
        while let message = try await replies.next() {
          logger.trace(
            "Received message from DBUS",
            metadata: [
              "replyTo": "\(String(describing: message.replyTo))"
            ])
          if let replyTo = message.replyTo,
            let continuation = continuations.removeValue(forKey: replyTo)
          {
            continuation.yield(message)
            continuation.finish()
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

        let iterator = replyStream.makeAsyncIterator()
        do {
          let reply = try await Self.awaitReply(
            timeoutNanoseconds: timeoutNanoseconds,
            iterator: ReplyIteratorBox(iterator: iterator)
          )
          return reply
        } catch {
          continuations.removeValue(forKey: requestId)?.finish(throwing: error)
          throw error
        }
      }

      public func setMessageHandler(
        _ handler: @escaping @Sendable (DBusMessage) async -> Void
      ) async {
        messageHandler = handler
      }

      private struct ReplyIteratorBox: @unchecked Sendable {
        let iterator: AsyncThrowingStream<DBusMessage, Error>.AsyncIterator
      }

      private static func awaitReply(
        timeoutNanoseconds: UInt64?,
        iterator: ReplyIteratorBox
      ) async throws -> DBusMessage {
        if let timeoutNanoseconds {
          let reply = try await withTimeout(timeoutNanoseconds) {
            var localIterator = iterator.iterator
            return try await localIterator.next()
          }
          guard let reply else {
            throw DBusError.missingReply
          }
          return reply
        }
        var localIterator = iterator.iterator
        guard let reply = try await localIterator.next() else {
          throw DBusError.missingReply
        }
        return reply
      }

      private static func withTimeout<T: Sendable>(
        _ nanoseconds: UInt64,
        operation: @Sendable @escaping () async throws -> T
      ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
          group.addTask {
            try await operation()
          }
          group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw DBusError.timeout
          }
          let result = try await group.next()
          group.cancelAll()
          guard let result else {
            throw DBusError.timeout
          }
          return result
        }
      }
    }

    /// Connects to a D-Bus address and executes a handler with the connection.
    public static func withConnection<R: Sendable>(
      to address: SocketAddress,
      auth: AuthType,
      enableUnixFDs: Bool = true,
      logger: Logger = Logger(label: "dbus.client.unixfd"),
      _ handler: @Sendable @escaping (Connection) async throws -> R
    ) async throws -> R {
      let socket = try UnixFDSocket.connect(to: address)
      var lineBuffer: [UInt8] = []
      let unixFdsNegotiated = try authenticate(
        fd: socket.fd,
        auth: auth,
        enableUnixFDs: enableUnixFDs,
        logger: logger,
        lineBuffer: &lineBuffer
      )
      let initialBytes = lineBuffer
      lineBuffer.removeAll(keepingCapacity: true)

      var continuationBox: ContinuationBox!
      let stream = AsyncThrowingStream<DBusMessage, Error> { streamContinuation in
        continuationBox = ContinuationBox(streamContinuation)
      }
      let continuation = continuationBox!

      let socketFd = socket.fd
      DispatchQueue.global(qos: .utility).async { [initialBytes] in
        var readSocket = UnixFDSocket(fd: socketFd)
        var decodeBuffer = ByteBufferAllocator().buffer(capacity: 0)
        if !initialBytes.isEmpty {
          decodeBuffer.writeBytes(initialBytes)
        }
        var fdQueue: [CInt] = []
        do {
          while let message = try readSocket.receiveMessage(
            buffer: &decodeBuffer, fdQueue: &fdQueue)
          {
            continuation.continuation.yield(message)
          }
          continuation.continuation.finish()
        } catch {
          continuation.continuation.finish(throwing: error)
        }
      }

      defer {
        socket.close()
        continuation.continuation.finish()
      }

      var replies = Replies(iterator: stream.makeAsyncIterator())
      let send = Send(socket: socket, unixFdsEnabled: unixFdsNegotiated)
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

    /// Connects to a parsed D-Bus address and executes a handler with the connection.
    public static func withConnection<R: Sendable>(
      to address: DBusAddress,
      auth: AuthType,
      enableUnixFDs: Bool = true,
      logger: Logger = Logger(label: "dbus.client.unixfd"),
      _ handler: @Sendable @escaping (Connection) async throws -> R
    ) async throws -> R {
      switch address {
      case .unix, .unixAbstract:
        let socket = try address.unixSocketAddress()
        return try await withConnection(
          to: socket,
          auth: auth,
          enableUnixFDs: enableUnixFDs,
          logger: logger,
          handler
        )
      case .tcp, .nonceTcp:
        throw DBusError.unixFdUnsupported
      }
    }

    /// Connects to a D-Bus address string and executes a handler with the connection.
    public static func withConnection<R: Sendable>(
      to address: String,
      auth: AuthType,
      enableUnixFDs: Bool = true,
      logger: Logger = Logger(label: "dbus.client.unixfd"),
      _ handler: @Sendable @escaping (Connection) async throws -> R
    ) async throws -> R {
      let parsedAddress = try DBusAddress.parse(address)
      return try await withConnection(
        to: parsedAddress,
        auth: auth,
        enableUnixFDs: enableUnixFDs,
        logger: logger,
        handler
      )
    }

    /// Connects to the session bus resolved from the environment.
    public static func withSessionBus<R: Sendable>(
      auth: AuthType,
      enableUnixFDs: Bool = true,
      logger: Logger = Logger(label: "dbus.client.unixfd"),
      _ handler: @Sendable @escaping (Connection) async throws -> R
    ) async throws -> R {
      let address = try DBusAddress.sessionBusAddress()
      return try await withConnection(
        to: address,
        auth: auth,
        enableUnixFDs: enableUnixFDs,
        logger: logger,
        handler
      )
    }

    /// Connects to the system bus resolved from the environment.
    public static func withSystemBus<R: Sendable>(
      auth: AuthType,
      enableUnixFDs: Bool = true,
      logger: Logger = Logger(label: "dbus.client.unixfd"),
      _ handler: @Sendable @escaping (Connection) async throws -> R
    ) async throws -> R {
      let address = try DBusAddress.systemBusAddress()
      return try await withConnection(
        to: address,
        auth: auth,
        enableUnixFDs: enableUnixFDs,
        logger: logger,
        handler
      )
    }

    private static func authenticate(
      fd: CInt,
      auth: AuthType,
      enableUnixFDs: Bool,
      logger: Logger,
      lineBuffer: inout [UInt8]
    ) throws -> Bool {
      var mechanisms = DBusAuthMechanism.preferred(for: auth)
      guard !mechanisms.isEmpty else {
        throw DBusAuthenticationError.invalidAuthCommand
      }

      try sendAll(fd: fd, bytes: [0])

      func nextMechanism(allowed: Set<String>?) -> DBusAuthMechanism? {
        while let candidate = mechanisms.first {
          mechanisms.removeFirst()
          if let allowed, !allowed.contains(candidate.name) {
            continue
          }
          return candidate
        }
        return nil
      }

      guard var current = nextMechanism(allowed: nil) else {
        throw DBusAuthenticationError.invalidAuthCommand
      }

      var authLine = try current.authLine()
      try sendAll(fd: fd, bytes: Array(authLine.utf8))

      while true {
        let line = try readLine(fd: fd, buffer: &lineBuffer, stripLeadingNulls: true)
        logger.trace("Authentication response", metadata: ["response": "\(line)"])

        if line.starts(with: "DATA ") {
          let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
          let response = try current.cookieResponse(for: payload)
          try sendAll(fd: fd, bytes: Array(response.utf8))
          continue
        }

        if line.starts(with: "OK ") {
          break
        }

        if line.starts(with: "REJECTED") || line.starts(with: "ERROR") {
          let trimmed =
            line.starts(with: "REJECTED")
            ? line.dropFirst("REJECTED".count)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
          let offered = trimmed.isEmpty ? nil : Set(trimmed.split(separator: " ").map(String.init))
          guard let next = nextMechanism(allowed: offered) else {
            throw DBusAuthenticationError.invalidAuthCommand
          }
          current = next
          authLine = try current.authLine()
          try sendAll(fd: fd, bytes: Array(authLine.utf8))
          continue
        }

        throw DBusAuthenticationError.invalidAuthCommand
      }

      var negotiated = false
      if enableUnixFDs {
        try sendAll(fd: fd, bytes: Array("NEGOTIATE_UNIX_FD\r\n".utf8))
        let response = try readLine(fd: fd, buffer: &lineBuffer, stripLeadingNulls: false)
        if response.starts(with: "AGREE_UNIX_FD") {
          negotiated = true
        } else if response.starts(with: "ERROR") {
          negotiated = false
        } else {
          throw DBusAuthenticationError.invalidAuthCommand
        }
      }

      try sendAll(fd: fd, bytes: Array("BEGIN\r\n".utf8))
      return negotiated
    }

    private static func sendAll(fd: CInt, bytes: [UInt8]) throws {
      var offset = 0
      while offset < bytes.count {
        let remaining = bytes.count - offset
        let written = bytes.withUnsafeBytes { rawBuffer -> Int in
          let base = rawBuffer.baseAddress!.advanced(by: offset)
          return Glibc.send(fd, base, remaining, 0)
        }

        if written < 0 {
          throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if written == 0 {
          throw POSIXError(POSIXErrorCode.EPIPE)
        }
        offset += written
      }
    }

    private static func readLine(
      fd: CInt,
      buffer: inout [UInt8],
      stripLeadingNulls: Bool
    ) throws -> String {
      while true {
        if stripLeadingNulls {
          while let first = buffer.first, first == 0 {
            buffer.removeFirst()
          }
        }
        if let newlineIndex = buffer.firstIndex(of: 10) {
          let lineBytes = buffer.prefix(upTo: newlineIndex)
          buffer.removeSubrange(...newlineIndex)
          let trimmed = lineBytes.last == 13 ? lineBytes.dropLast() : lineBytes
          return String(decoding: trimmed, as: UTF8.self)
        }

        var chunk = [UInt8](repeating: 0, count: 256)
        let count = Glibc.recv(fd, &chunk, chunk.count, 0)
        if count < 0 {
          throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if count == 0 {
          throw DBusError.earlyEOF
        }
        buffer.append(contentsOf: chunk.prefix(count))
      }
    }
  }
#else
  @available(macOS 10.15, iOS 13, *)
  /// A D-Bus client that supports UNIX_FD passing (Linux only).
  ///
  /// On platforms without `Glibc`, these APIs throw ``DBusError/unixFdUnsupported``.
  public enum DBusUnixFDClient {
    public struct Replies: @unchecked Sendable {
      public init() {}
      public mutating func next() async throws -> DBusMessage? {
        throw DBusError.unixFdUnsupported
      }
    }

    public actor Send {
      public init() {}
      public func reserveSerial() -> UInt32 { 0 }
      public func send(_ request: DBusRequest) async throws -> UInt32 {
        throw DBusError.unixFdUnsupported
      }
      public func send(_ message: DBusMessage) async throws { throw DBusError.unixFdUnsupported }
    }

    public actor Connection: Sendable {
      public init() {}
      public func send(_ request: DBusRequest) async throws -> DBusMessage? {
        throw DBusError.unixFdUnsupported
      }
      public func send(_ request: DBusRequest, timeoutNanoseconds: UInt64?) async throws
        -> DBusMessage?
      {
        _ = timeoutNanoseconds
        throw DBusError.unixFdUnsupported
      }
      public func setMessageHandler(_ handler: @escaping @Sendable (DBusMessage) async -> Void)
        async
      {
        _ = handler
      }
    }

    public static func withConnection<R: Sendable>(
      to address: SocketAddress,
      auth: AuthType,
      enableUnixFDs: Bool = true,
      logger: Logger = Logger(label: "dbus.client.unixfd"),
      _ handler: @Sendable @escaping (Connection) async throws -> R
    ) async throws -> R {
      _ = address
      _ = auth
      _ = enableUnixFDs
      _ = logger
      _ = handler
      throw DBusError.unixFdUnsupported
    }

    public static func withConnection<R: Sendable>(
      to address: DBusAddress,
      auth: AuthType,
      enableUnixFDs: Bool = true,
      logger: Logger = Logger(label: "dbus.client.unixfd"),
      _ handler: @Sendable @escaping (Connection) async throws -> R
    ) async throws -> R {
      _ = address
      _ = auth
      _ = enableUnixFDs
      _ = logger
      _ = handler
      throw DBusError.unixFdUnsupported
    }

    public static func withConnection<R: Sendable>(
      to address: String,
      auth: AuthType,
      enableUnixFDs: Bool = true,
      logger: Logger = Logger(label: "dbus.client.unixfd"),
      _ handler: @Sendable @escaping (Connection) async throws -> R
    ) async throws -> R {
      _ = address
      _ = auth
      _ = enableUnixFDs
      _ = logger
      _ = handler
      throw DBusError.unixFdUnsupported
    }

    public static func withSessionBus<R: Sendable>(
      auth: AuthType,
      enableUnixFDs: Bool = true,
      logger: Logger = Logger(label: "dbus.client.unixfd"),
      _ handler: @Sendable @escaping (Connection) async throws -> R
    ) async throws -> R {
      _ = auth
      _ = enableUnixFDs
      _ = logger
      _ = handler
      throw DBusError.unixFdUnsupported
    }

    public static func withSystemBus<R: Sendable>(
      auth: AuthType,
      enableUnixFDs: Bool = true,
      logger: Logger = Logger(label: "dbus.client.unixfd"),
      _ handler: @Sendable @escaping (Connection) async throws -> R
    ) async throws -> R {
      _ = auth
      _ = enableUnixFDs
      _ = logger
      _ = handler
      throw DBusError.unixFdUnsupported
    }
  }
#endif
