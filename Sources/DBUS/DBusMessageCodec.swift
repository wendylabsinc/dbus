import Logging
import NIO

struct DBusMessageDecoder: ByteToMessageDecoder {
  typealias InboundOut = DBusMessage

  private let logger: Logger

  init(logger: Logger) {
    self.logger = logger
  }

  func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
    logger.debug("DBusMessageDecoder: Decoding message from buffer with \(buffer.readableBytes) bytes")
    let index = buffer.readerIndex
    do {
      let msg = try DBusMessage(from: &buffer)
      buffer.discardReadBytes()
      logger.debug(
        "DBusMessageDecoder: Successfully decoded D-Bus message",
        metadata: [
          "type": "\(msg.messageType)",
          "serial": "\(msg.serial)",
          "path": "\(msg.path ?? "nil")",
          "interface": "\(msg.interface ?? "nil")",
          "member": "\(msg.member ?? "nil")"
        ]
      )
      context.fireChannelRead(self.wrapInboundOut(msg))
      return .continue
    } catch DBusError.truncatedHeaderFields, DBusError.truncatedBody, DBusError.earlyEOF {
      // Not enough data yet
      logger.trace("Not enough data for complete message, waiting for more")
      buffer.moveReaderIndex(to: index)
      return .needMoreData
    } catch {
      logger.warning(
        "DBusMessageDecoder: Failed to decode D-Bus message",
        metadata: [
          "error": "\(error)"
        ])
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
    try data.validate(allowUnixFds: false, unixFdsError: .unixFdUnsupported)
    logger.trace(
      "Encoding D-Bus message",
      metadata: [
        "type": "\(data.messageType)",
        "serial": "\(data.serial)",
      ])
    data.write(to: &out)
    logger.trace(
      "Encoded message to bytes",
      metadata: [
        "byte-size": "\(out.readableBytes)"
      ])
  }
}
