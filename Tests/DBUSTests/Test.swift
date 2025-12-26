import NIOCore
import Testing

@testable import DBUS

@Suite
struct MessageTests {
  @Test
  func decodeMessageBody() throws {
    let bytes: [UInt8] = [
      108, 2, 1, 1, 10, 0, 0, 0, 1, 0, 0, 0, 61, 0, 0, 0, 6, 1, 115, 0, 5, 0, 0, 0, 58, 49, 46, 54,
      54, 0, 0, 0, 5, 1, 117, 0, 1, 0, 0, 0, 8, 1, 103, 0, 1, 115, 0, 0, 7, 1, 115, 0, 20, 0, 0, 0,
      111, 114, 103, 46, 102, 114, 101, 101, 100, 101, 115, 107, 116, 111, 112, 46, 68, 66, 117,
      115, 0, 0, 0, 0, 5, 0, 0, 0, 58, 49, 46, 54, 54, 0, 108, 4, 1, 1, 10, 0, 0, 0, 2, 0, 0, 0,
      141, 0, 0, 0, 1, 1, 111, 0, 21, 0, 0, 0, 47, 111, 114, 103, 47, 102, 114, 101, 101, 100, 101,
      115, 107, 116, 111, 112, 47, 68, 66, 117, 115, 0, 0, 0, 2, 1, 115, 0, 20, 0, 0, 0, 111, 114,
      103, 46, 102, 114, 101, 101, 100, 101, 115, 107, 116, 111, 112, 46, 68, 66, 117, 115, 0, 0, 0,
      0, 3, 1, 115, 0, 12, 0, 0, 0, 78, 97, 109, 101, 65, 99, 113, 117, 105, 114, 101, 100, 0, 0, 0,
      0, 6, 1, 115, 0, 5, 0, 0, 0, 58, 49, 46, 54, 54, 0, 0, 0, 8, 1, 103, 0, 1, 115, 0, 0, 7, 1,
      115, 0, 20, 0, 0, 0, 111, 114, 103, 46, 102, 114, 101, 101, 100, 101, 115, 107, 116, 111, 112,
      46, 68, 66, 117, 115, 0, 0, 0, 0, 5, 0, 0, 0, 58, 49, 46, 54, 54, 0,
    ]

    var buffer = ByteBuffer(bytes: bytes)
    var writeBuffer = ByteBuffer()

    while buffer.readableBytes > 0 {
      let message = try DBusMessage(from: &buffer)
      buffer.discardReadBytes()

      var writeBuffer2 = ByteBuffer()
      message.write(to: &writeBuffer2)
      writeBuffer.writeImmutableBuffer(writeBuffer2)
    }

    while writeBuffer.readableBytes > 0 {
      _ = try DBusMessage(from: &writeBuffer)
      writeBuffer.discardReadBytes()
    }
  }
    
    @Test func decodeBooleanMessage() throws {
        let bytes: [UInt8] = [108, 2, 1, 1, 4, 0, 0, 0, 3, 0, 0, 0, 61, 0, 0, 0, 6, 1, 115, 0, 5, 0, 0, 0, 58, 49, 46, 49, 48, 0, 0, 0, 5, 1, 117, 0, 2, 0, 0, 0, 8, 1, 103, 0, 1, 98, 0, 0, 7, 1, 115, 0, 20, 0, 0, 0, 111, 114, 103, 46, 102, 114, 101, 101, 100, 101, 115, 107, 116, 111, 112, 46, 68, 66, 117, 115, 0, 0, 0, 0, 1, 0, 0, 0]
        
        var buffer = ByteBuffer(bytes: bytes)
        _ = try DBusMessage(from: &buffer)
    }

  @Test func decodeBooleanMessage2() throws {
    let bytes: [UInt8] = [
      108, 2, 1, 1, 4, 0, 0, 0, 3, 0, 0, 0, 61, 0, 0, 0, 6, 1, 115, 0, 5, 0, 0, 0, 58, 49, 46, 49,
      48, 0, 0, 0, 5, 1, 117, 0, 2, 0, 0, 0, 8, 1, 103, 0, 1, 98, 0, 0, 7, 1, 115, 0, 20, 0, 0, 0,
      111, 114, 103, 46, 102, 114, 101, 101, 100, 101, 115, 107, 116, 111, 112, 46, 68, 66, 117,
      115, 0, 0, 0, 0, 1, 0, 0, 0,
    ]

    var buffer = ByteBuffer(bytes: bytes)
    _ = try DBusMessage(from: &buffer)
  }

  @Test func createMethodCall() throws {
    let message = DBusMessage.createMethodCall(
      destination: "org.freedesktop.NetworkManager",
      path: "/org/freedesktop/NetworkManager/AccessPoint/1",
      interface: "org.freedesktop.DBus.Properties",
      method: "Get",
      serial: 2,
      body: [
        DBusValue.string("org.freedesktop.NetworkManager.AccessPoint"), DBusValue.string("Ssid"),
      ]
    )

    var buffer = ByteBuffer()
    message.write(to: &buffer)

    let message2 = try DBusMessage(from: &buffer)
    #expect(message.body == message2.body)
  }

  @Test func rootObjectPathIsValid() throws {
    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 1,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/"))),
        HeaderField(code: .member, variant: DBusVariant(.string("Ping"))),
      ],
      body: []
    )

    var buffer = ByteBuffer()
    message.write(to: &buffer)

    let decoded = try DBusMessage(from: &buffer)
    #expect(decoded.path == "/")
  }

  @Test func objectPathRejectsInvalidCharacters() throws {
    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 2,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/bad-path"))),
        HeaderField(code: .member, variant: DBusVariant(.string("Ping"))),
      ],
      body: []
    )

    var buffer = ByteBuffer()
    message.write(to: &buffer)

    do {
      _ = try DBusMessage(from: &buffer)
      #expect(Bool(false), "Expected invalidHeaderField error")
    } catch DBusError.invalidHeaderField {
      // Expected.
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }

  @Test func decodeDictionaryBody() throws {
    let bodyDict: [DBusValue: DBusValue] = [
      .string("name"): .variant(DBusVariant(.string("value"))),
      .string("count"): .variant(DBusVariant(.int32(42))),
    ]

    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodReturn,
      flags: [],
      protocolVersion: 1,
      serial: 2,
      headerFields: [
        HeaderField(code: .replySerial, variant: DBusVariant(.uint32(1))),
        HeaderField(code: .signature, variant: DBusVariant(.signature("a{sv}"))),
      ],
      body: [.dictionary(bodyDict)]
    )

    var buffer = ByteBuffer()
    message.write(to: &buffer)

    let decoded = try DBusMessage(from: &buffer)
    guard let first = decoded.body.first else {
      #expect(Bool(false), "Expected a dictionary body")
      return
    }
    guard case .dictionary(let decodedDict) = first else {
      #expect(Bool(false), "Expected dictionary to decode as .dictionary")
      return
    }
    #expect(decodedDict == bodyDict)
  }

  @Test func parseArgumentsRejectsTrailingBodyBytes() throws {
    var body = ByteBuffer()
    DBusString.write("hello", to: &body, byteOrder: .little)
    body.writeInteger(UInt8(0xFF))

    let headerFields = [
      HeaderField(code: .signature, variant: DBusVariant(.signature("s")))
    ]

    do {
      _ = try DBusMessage.parseArguments(
        headerFields: headerFields,
        body: &body,
        byteOrder: .little
      )
      #expect(Bool(false), "Expected invalidBody error")
    } catch DBusError.invalidBody {
      // Expected.
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }

  @Test func parseArgumentsRejectsEmptySignatureWithBody() throws {
    var body = ByteBuffer()
    body.writeInteger(UInt8(0x01))

    let headerFields = [
      HeaderField(code: .signature, variant: DBusVariant(.signature("")))
    ]

    do {
      _ = try DBusMessage.parseArguments(
        headerFields: headerFields,
        body: &body,
        byteOrder: .little
      )
      #expect(Bool(false), "Expected invalidBody error")
    } catch DBusError.invalidBody {
      // Expected.
    } catch {
      #expect(Bool(false), "Unexpected error: \(error)")
    }
  }

  @Test func signatureOverrideForEmptyArray() throws {
    let request = DBusRequest.createMethodCall(
      destination: "org.example.Test",
      path: "/org/example/Test",
      interface: "org.example.Test",
      method: "EmptyArray",
      body: [.array([])],
      signature: "ai"
    )

    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 1,
      headerFields: request.headerFields,
      body: request.body
    )

    var buffer = ByteBuffer()
    message.write(to: &buffer)

    let decoded = try DBusMessage(from: &buffer)
    guard let signatureField = decoded.headerFields.first(where: { $0.code == .signature }) else {
      #expect(Bool(false), "Expected signature header field")
      return
    }
    guard case .signature(let signature) = signatureField.variant.value else {
      #expect(Bool(false), "Expected signature header to contain a signature value")
      return
    }
    #expect(signature == "ai")
  }

  @Test func signatureOverrideForEmptyDictionary() throws {
    let request = DBusRequest.createMethodCall(
      destination: "org.example.Test",
      path: "/org/example/Test",
      interface: "org.example.Test",
      method: "EmptyDict",
      body: [.dictionary([:])],
      signature: "a{ss}"
    )

    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 2,
      headerFields: request.headerFields,
      body: request.body
    )

    var buffer = ByteBuffer()
    message.write(to: &buffer)

    let decoded = try DBusMessage(from: &buffer)
    guard let signatureField = decoded.headerFields.first(where: { $0.code == .signature }) else {
      #expect(Bool(false), "Expected signature header field")
      return
    }
    guard case .signature(let signature) = signatureField.variant.value else {
      #expect(Bool(false), "Expected signature header to contain a signature value")
      return
    }
    #expect(signature == "a{ss}")
  }

  @Test func unixFdsHeaderIsWritten() throws {
    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 3,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/org/example/Test"))),
        HeaderField(code: .interface, variant: DBusVariant(.string("org.example.Test"))),
        HeaderField(code: .member, variant: DBusVariant(.string("WithFds"))),
        HeaderField(code: .signature, variant: DBusVariant(.signature("hh"))),
      ],
      body: [.unixFd(0), .unixFd(1)],
      unixFds: [10, 11]
    )

    var buffer = ByteBuffer()
    message.write(to: &buffer)

    let decoded = try DBusMessage(from: &buffer)
    #expect(decoded.unixFdsCount == 2)
  }
}
