import Logging
import NIO
import Testing

@testable import DBUS

@Suite
struct DBusClientTests {
  @Test func sendDoesNotMissFastReply() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let server = try await ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 16)
      .childChannelInitializer { channel in
        do {
          try channel.pipeline.syncOperations.addHandlers(
            ByteToMessageHandler(DBusMessageDecoder(logger: Logger(label: "dbus.test.server"))),
            MessageToByteHandler(DBusMessageEncoder(logger: Logger(label: "dbus.test.server"))),
            ServerReplyHandler()
          )
          return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }
      .bind(host: "127.0.0.1", port: 0)
      .get()

    let address = server.localAddress!

    do {
      let clientChannel = try await ClientBootstrap(group: group)
        .channelInitializer { channel in
          do {
            try channel.pipeline.syncOperations.addHandlers(
              DelayWriteHandler(delay: .milliseconds(50)),
              ByteToMessageHandler(DBusMessageDecoder(logger: Logger(label: "dbus.test.client"))),
              MessageToByteHandler(DBusMessageEncoder(logger: Logger(label: "dbus.test.client")))
            )
            return channel.eventLoop.makeSucceededVoidFuture()
          } catch {
            return channel.eventLoop.makeFailedFuture(error)
          }
        }
        .connect(to: address)
        .get()

      let asyncChannel = try await clientChannel.eventLoop.submit {
        try NIOAsyncChannel(
          wrappingChannelSynchronously: clientChannel,
          configuration: .init(inboundType: DBusMessage.self, outboundType: DBusMessage.self)
        )
      }.get()

      let reply = try await asyncChannel.executeThenClose { inbound, outbound in
        var replies = DBusClient.Replies(iterator: inbound.makeAsyncIterator())
        let send = DBusClient.Send(writer: outbound)
        let connection = DBusClient.Connection(
          send: send, logger: Logger(label: "dbus.test.client"))

        async let _ = connection.run(replies: &replies)

        let request = DBusRequest.createMethodCall(
          destination: "org.test.Service",
          path: "/org/test/Object",
          interface: "org.test.Interface",
          method: "Ping"
        )

        return try await withTimeout(500_000_000) {
          try await connection.send(request)
        }
      }

      #expect(reply?.messageType == .methodReturn)
    } catch {
      _ = try? await server.close().get()
      _ = try? await shutdownGroup(group)
      throw error
    }

    _ = try await server.close().get()
    try await shutdownGroup(group)
  }

  @Test func serialGeneratorSkipsZeroOnWrap() throws {
    #expect(DBusSerialGenerator.next(after: 0) == 1)
    #expect(DBusSerialGenerator.next(after: UInt32.max - 1) == UInt32.max)
    #expect(DBusSerialGenerator.next(after: UInt32.max) == 1)
  }

  @Test func sendTimesOutWhenReplyMissing() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    let server = try await ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 16)
      .childChannelInitializer { channel in
        do {
          try channel.pipeline.syncOperations.addHandlers(
            ByteToMessageHandler(DBusMessageDecoder(logger: Logger(label: "dbus.test.server"))),
            MessageToByteHandler(DBusMessageEncoder(logger: Logger(label: "dbus.test.server"))),
            NoReplyHandler()
          )
          return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }
      .bind(host: "127.0.0.1", port: 0)
      .get()

    let address = server.localAddress!

    do {
      let clientChannel = try await ClientBootstrap(group: group)
        .channelInitializer { channel in
          do {
            try channel.pipeline.syncOperations.addHandlers(
              ByteToMessageHandler(DBusMessageDecoder(logger: Logger(label: "dbus.test.client"))),
              MessageToByteHandler(DBusMessageEncoder(logger: Logger(label: "dbus.test.client")))
            )
            return channel.eventLoop.makeSucceededVoidFuture()
          } catch {
            return channel.eventLoop.makeFailedFuture(error)
          }
        }
        .connect(to: address)
        .get()

      let asyncChannel = try await clientChannel.eventLoop.submit {
        try NIOAsyncChannel(
          wrappingChannelSynchronously: clientChannel,
          configuration: .init(inboundType: DBusMessage.self, outboundType: DBusMessage.self)
        )
      }.get()

      _ = try await asyncChannel.executeThenClose { inbound, outbound in
        var replies = DBusClient.Replies(iterator: inbound.makeAsyncIterator())
        let send = DBusClient.Send(writer: outbound)
        let connection = DBusClient.Connection(
          send: send, logger: Logger(label: "dbus.test.client"))

        async let _ = connection.run(replies: &replies)

        let request = DBusRequest.createMethodCall(
          destination: "org.test.Service",
          path: "/org/test/Object",
          interface: "org.test.Interface",
          method: "NoReply"
        )

        do {
          _ = try await connection.send(request, timeoutNanoseconds: 50_000_000)
          #expect(Bool(false), "Expected timeout error")
        } catch DBusError.timeout {
          // Expected.
        } catch {
          #expect(Bool(false), "Unexpected error: \(error)")
        }

        return true
      }
    } catch {
      _ = try? await server.close().get()
      _ = try? await shutdownGroup(group)
      throw error
    }

    _ = try await server.close().get()
    try await shutdownGroup(group)
  }
}

private final class DelayWriteHandler: ChannelDuplexHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private let delay: TimeAmount

  init(delay: TimeAmount) {
    self.delay = delay
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    context.fireChannelRead(data)
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    context.write(data, promise: nil)
    context.flush()

    if let promise {
      let scheduled = context.eventLoop.scheduleTask(in: delay) {}
      scheduled.futureResult.cascade(to: promise)
    }
  }
}

private final class ServerReplyHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = DBusMessage
  typealias OutboundOut = DBusMessage

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let message = unwrapInboundIn(data)
    guard message.messageType == .methodCall else { return }

    let reply = DBusMessage(
      byteOrder: message.byteOrder,
      messageType: .methodReturn,
      flags: [],
      protocolVersion: message.protocolVersion,
      serial: message.serial &+ 1,
      headerFields: [
        HeaderField(code: .replySerial, variant: DBusVariant(.uint32(message.serial)))
      ],
      body: []
    )
    context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
  }
}

private final class NoReplyHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = DBusMessage

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    _ = unwrapInboundIn(data)
  }
}

private struct UncheckedSendable<T>: @unchecked Sendable {
  let value: T
}

private struct TimeoutError: Error {}

private func shutdownGroup(_ group: EventLoopGroup) async throws {
  let sendableGroup = UncheckedSendable(value: group)
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    sendableGroup.value.shutdownGracefully { error in
      if let error {
        continuation.resume(throwing: error)
      } else {
        continuation.resume()
      }
    }
  }
}

private func withTimeout<T: Sendable>(
  _ nanoseconds: UInt64,
  operation: @Sendable @escaping () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(nanoseconds: nanoseconds)
      throw TimeoutError()
    }
    let result = try await group.next()
    group.cancelAll()
    guard let result else {
      throw TimeoutError()
    }
    return result
  }
}
