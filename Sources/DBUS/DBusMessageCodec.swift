import Logging
import NIO

struct DBusMessageDecoder: ByteToMessageDecoder {
  typealias InboundOut = DBusMessage

  private let logger: Logger

  init(logger: Logger) {
    self.logger = logger
  }

  func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
    let index = buffer.readerIndex
    do {
      let msg = try DBusMessage(from: &buffer)
      buffer.discardReadBytes()
      logger.trace(
        "Decoded D-Bus message",
        metadata: [
          "type": "\(msg.messageType)",
          "serial": "\(msg.serial)",
          "path": "\(msg.path ?? "nil")",
          "interface": "\(msg.interface ?? "nil")",
          "member": "\(msg.member ?? "nil")",
        ]
      )
      context.fireChannelRead(self.wrapInboundOut(msg))
      return .continue
    } catch DBusError.truncatedHeaderFields, DBusError.truncatedBody, DBusError.earlyEOF {
      // Not enough data yet
      buffer.moveReaderIndex(to: index)
      return .needMoreData
    } catch {
      logger.warning(
        "Failed to decode D-Bus message",
        metadata: ["error": "\(error)"])
      throw error
    }
  }
}

struct DBusMessageEncoder: MessageToByteEncoder {
  typealias OutboundIn = DBusMessage

  private let logger: Logger

  init(logger: Logger) {
    self.logger = logger
  }

  func encode(data: DBusMessage, out: inout ByteBuffer) throws {
    logger.trace(
      "Encoding D-Bus message",
      metadata: [
        "type": "\(data.messageType)",
        "serial": "\(data.serial)",
        "path": "\(data.path ?? "nil")",
        "interface": "\(data.interface ?? "nil")",
        "member": "\(data.member ?? "nil")",
        "destination": "\(data.destination ?? "nil")"
      ])
    do {
      try data.validate(allowUnixFds: false, unixFdsError: .unixFdUnsupported)
    } catch {
      logger.error("D-Bus message validation failed", metadata: ["error": "\(error)"])
      throw error
    }
    data.write(to: &out)
    logger.trace("Encoded D-Bus message", metadata: ["byteSize": "\(out.readableBytes)"])
  }
}
