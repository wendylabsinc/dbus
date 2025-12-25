import Logging
import NIO
import NIOCore
import Testing

@testable import DBUS

@Suite
struct DBusMessageCodecTests {
  private func makeEncoderChannel() throws -> EmbeddedChannel {
    let channel = EmbeddedChannel()
    try channel.pipeline.syncOperations.addHandler(
      MessageToByteHandler(DBusMessageEncoder(logger: Logger(label: "dbus.test.encoder")))
    )
    return channel
  }

  @Test func decoderHandlesPartialHeader() throws {
    let channel = EmbeddedChannel()
    try channel.pipeline.syncOperations.addHandler(
      ByteToMessageHandler(DBusMessageDecoder(logger: Logger(label: "dbus.test.decoder")))
    )

    var buffer = channel.allocator.buffer(capacity: 4)
    buffer.writeBytes([0x6C, 0x01, 0x00, 0x01])

    do {
      try channel.writeInbound(buffer)
    } catch {
      #expect(Bool(false), "Decoder should request more data, not throw: \(error)")
    }

    let message = try channel.readInbound(as: DBusMessage.self)
    #expect(message == nil)

    try channel.close().wait()
  }

  @Test func decoderHandlesPartialSecondMessageAfterFull() throws {
    let channel = EmbeddedChannel()
    try channel.pipeline.syncOperations.addHandler(
      ByteToMessageHandler(DBusMessageDecoder(logger: Logger(label: "dbus.test.decoder")))
    )

    let firstMessage = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 1,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/test/path"))),
        HeaderField(code: .member, variant: DBusVariant(.string("First"))),
      ],
      body: []
    )
    var firstBuffer = channel.allocator.buffer(capacity: 0)
    firstMessage.write(to: &firstBuffer)

    let secondMessage = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 2,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/test/path"))),
        HeaderField(code: .member, variant: DBusVariant(.string("Second"))),
      ],
      body: []
    )
    var secondBuffer = channel.allocator.buffer(capacity: 0)
    secondMessage.write(to: &secondBuffer)

    let secondBytes = Array(secondBuffer.readableBytesView)
    let splitIndex = max(1, secondBytes.count / 2)

    var combined = channel.allocator.buffer(capacity: 0)
    combined.writeBuffer(&firstBuffer)
    combined.writeBytes(secondBytes.prefix(splitIndex))

    try channel.writeInbound(combined)

    let firstDecoded = try channel.readInbound(as: DBusMessage.self)
    #expect(firstDecoded?.serial == 1)
    #expect(try channel.readInbound(as: DBusMessage.self) == nil)

    var remainder = channel.allocator.buffer(capacity: 0)
    remainder.writeBytes(secondBytes.suffix(secondBytes.count - splitIndex))
    try channel.writeInbound(remainder)

    let secondDecoded = try channel.readInbound(as: DBusMessage.self)
    #expect(secondDecoded?.serial == 2)

    try channel.close().wait()
  }

  @Test func encoderRejectsUnixFds() throws {
    let channel = try makeEncoderChannel()
    defer { _ = try? channel.close().wait() }

    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 1,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/test/path"))),
        HeaderField(code: .member, variant: DBusVariant(.string("WithFds"))),
        HeaderField(code: .signature, variant: DBusVariant(.signature("h"))),
      ],
      body: [.unixFd(0)],
      unixFds: [10]
    )

    do {
      try channel.writeOutbound(message)
      #expect(Bool(false), "Expected unixFdUnsupported error")
    } catch DBusError.unixFdUnsupported {
      // Expected.
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }

  @Test func encoderRejectsSignatureMismatch() throws {
    let channel = try makeEncoderChannel()
    defer { _ = try? channel.close().wait() }

    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 1,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/test/path"))),
        HeaderField(code: .member, variant: DBusVariant(.string("Mismatch"))),
        HeaderField(code: .signature, variant: DBusVariant(.signature("s"))),
      ],
      body: [.uint32(1)]
    )

    do {
      try channel.writeOutbound(message)
      #expect(Bool(false), "Expected invalidBody error")
    } catch DBusError.invalidBody {
      // Expected.
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }

  @Test func encoderRejectsMixedArrayElements() throws {
    let channel = try makeEncoderChannel()
    defer { _ = try? channel.close().wait() }

    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 2,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/test/path"))),
        HeaderField(code: .member, variant: DBusVariant(.string("MixedArray"))),
        HeaderField(code: .signature, variant: DBusVariant(.signature("ai"))),
      ],
      body: [.array([.int32(1), .string("oops")])]
    )

    do {
      try channel.writeOutbound(message)
      #expect(Bool(false), "Expected invalidBody error")
    } catch DBusError.invalidBody {
      // Expected.
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }

  @Test func encoderRejectsVariantSignatureMismatch() throws {
    let channel = try makeEncoderChannel()
    defer { _ = try? channel.close().wait() }

    let badVariant = DBusVariant(signature: "s", value: .int32(1))
    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 3,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/test/path"))),
        HeaderField(code: .member, variant: DBusVariant(.string("BadVariant"))),
        HeaderField(code: .signature, variant: DBusVariant(.signature("v"))),
      ],
      body: [.variant(badVariant)]
    )

    do {
      try channel.writeOutbound(message)
      #expect(Bool(false), "Expected invalidBody error")
    } catch DBusError.invalidBody {
      // Expected.
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }

  @Test func encoderRejectsArrayForDictSignature() throws {
    let channel = try makeEncoderChannel()
    defer { _ = try? channel.close().wait() }

    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 4,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/test/path"))),
        HeaderField(code: .member, variant: DBusVariant(.string("BadDict"))),
        HeaderField(code: .signature, variant: DBusVariant(.signature("a{ss}"))),
      ],
      body: [.array([])]
    )

    do {
      try channel.writeOutbound(message)
      #expect(Bool(false), "Expected invalidBody error")
    } catch DBusError.invalidBody {
      // Expected.
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }

  @Test func validationRejectsUnusedUnixFds() throws {
    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 5,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/test/path"))),
        HeaderField(code: .member, variant: DBusVariant(.string("UnusedFds"))),
      ],
      body: [],
      unixFds: [10]
    )

    do {
      try message.validate(allowUnixFds: true, unixFdsError: .unixFdNotNegotiated)
      #expect(Bool(false), "Expected invalidBody error")
    } catch DBusError.invalidBody {
      // Expected.
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }

  @Test func validationRejectsMissingUnixFds() throws {
    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 6,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/test/path"))),
        HeaderField(code: .member, variant: DBusVariant(.string("MissingFds"))),
        HeaderField(code: .signature, variant: DBusVariant(.signature("h"))),
      ],
      body: [.unixFd(0)],
      unixFds: []
    )

    do {
      try message.validate(allowUnixFds: true, unixFdsError: .unixFdNotNegotiated)
      #expect(Bool(false), "Expected unixFdMissing error")
    } catch DBusError.unixFdMissing {
      // Expected.
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }
}
