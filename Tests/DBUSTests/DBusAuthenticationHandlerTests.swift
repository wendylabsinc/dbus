import Crypto
import Logging
import NIO
import NIOCore
import NIOExtras
import Testing

@testable import DBUS

#if canImport(FoundationEssentials)
  import FoundationEssentials
#elseif canImport(Foundation)
  import Foundation
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@Suite
struct DBusAuthenticationHandlerTests {
  // MARK: - Authentication Protocol Tests

  @Test func initialNulByteSending() throws {
    // Set up an embedded channel using DBusClient's configuration
    let channel = EmbeddedChannel()
    try DBusClient.addToPipeline(channel.pipeline, auth: .anonymous, enableUnixFDs: false)

    // Activate the channel
    channel.pipeline.fireChannelActive()

    // Verify the NUL byte was sent
    if let data = try channel.readOutbound(as: ByteBuffer.self) {
      #expect(data.readableBytes == 1, "Expected single-byte NUL preface")
      #expect(data.getInteger(at: 0, as: UInt8.self) == 0, "First byte should be NUL (0)")
    } else {
      #expect(Bool(false), "No outbound message was sent")
    }

    // Check the AUTH command follows
    if let authData = try channel.readOutbound(as: ByteBuffer.self) {
      let command = String(buffer: authData)
      #expect(command == "AUTH ANONYMOUS\r\n", "Expected ANONYMOUS auth command")
    } else {
      #expect(Bool(false), "No AUTH command was sent")
    }

    try channel.close().wait()
  }

  @Test func initialBytesAreSentBeforeNul() throws {
    let channel = EmbeddedChannel()
    let initialBytes: [UInt8] = [0x12, 0x34, 0x56]
    try DBusClient.addToPipeline(
      channel.pipeline, auth: .anonymous, enableUnixFDs: false, initialBytes: initialBytes)

    channel.pipeline.fireChannelActive()

    if let data = try channel.readOutbound(as: ByteBuffer.self) {
      let expectedLength = initialBytes.count + 1
      #expect(data.readableBytes == expectedLength, "Expected nonce bytes plus NUL")
      guard let sentBytes = data.getBytes(at: 0, length: initialBytes.count) else {
        #expect(Bool(false), "Expected nonce bytes to be readable")
        return
      }
      #expect(sentBytes == initialBytes, "Expected nonce bytes first")
      #expect(
        data.getInteger(at: initialBytes.count, as: UInt8.self) == 0,
        "Expected NUL byte after nonce"
      )
    } else {
      #expect(Bool(false), "No outbound message was sent")
    }

    _ = try channel.readOutbound(as: ByteBuffer.self)
    try channel.close().wait()
  }

  @Test func externalAuthentication() throws {
    // Test with a user ID that needs hex encoding
    let userId = "1000"
    let expectedHexUserId = userId.utf8.map { byte in
      let hexString = String(byte, radix: 16)
      return hexString.count == 1 ? "0\(hexString)" : hexString
    }.joined()

    let channel = EmbeddedChannel()
    try DBusClient.addToPipeline(
      channel.pipeline, auth: .external(userID: userId), enableUnixFDs: false)

    // Activate the channel
    channel.pipeline.fireChannelActive()

    // Verify the NUL byte was sent
    if let data = try channel.readOutbound(as: ByteBuffer.self) {
      #expect(data.readableBytes == 1, "Expected single-byte NUL preface")
      #expect(data.getInteger(at: 0, as: UInt8.self) == 0, "First byte should be NUL (0)")
    } else {
      #expect(Bool(false), "No outbound message was sent")
    }

    // Check the AUTH command follows the NUL byte with correctly encoded user ID
    if let authData = try channel.readOutbound(as: ByteBuffer.self) {
      let command = String(buffer: authData)
      #expect(
        command == "AUTH EXTERNAL \(expectedHexUserId)\r\n",
        "Expected EXTERNAL auth command with hex-encoded user ID")
    } else {
      #expect(Bool(false), "No AUTH command was sent")
    }

    try channel.close().wait()
  }

  @Test func cookieSha1FallbackComputesDigest() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keyringDir = tempDir.appendingPathComponent(".dbus-keyrings")
    try FileManager.default.createDirectory(at: keyringDir, withIntermediateDirectories: true)

    let context = "org_freedesktop_general"
    let cookieId = "1"
    let cookieValue = "cafebabe"
    let cookieLine = "\(cookieId) 0 \(cookieValue)\n"
    try cookieLine.write(
      to: keyringDir.appendingPathComponent(context),
      atomically: true,
      encoding: .utf8
    )

    let originalHome = ProcessInfo.processInfo.environment["HOME"]
    setenv("HOME", tempDir.path, 1)
    defer {
      if let originalHome {
        setenv("HOME", originalHome, 1)
      } else {
        unsetenv("HOME")
      }
    }

    #if canImport(Glibc) || canImport(Musl)
      let userId = String(getuid())
    #else
      let userId = "0"
    #endif

    let mechanisms = DBusAuthMechanism.preferred(for: .external(userID: userId))
    let cookieMechanism = mechanisms.first { mechanism in
      if case .cookieSha1 = mechanism { return true }
      return false
    }
    guard case .cookieSha1(let userName, _) = cookieMechanism else {
      #expect(Bool(false), "Expected cookie SHA1 mechanism")
      return
    }

    let channel = EmbeddedChannel()
    try DBusClient.addToPipeline(
      channel.pipeline, auth: .external(userID: userId), enableUnixFDs: false)
    channel.pipeline.fireChannelActive()

    _ = try channel.readOutbound(as: ByteBuffer.self)
    _ = try channel.readOutbound(as: ByteBuffer.self)

    var rejectedBuffer = channel.allocator.buffer(capacity: 64)
    rejectedBuffer.writeString("REJECTED DBUS_COOKIE_SHA1\r\n")
    try channel.writeInbound(rejectedBuffer)

    if let authData = try channel.readOutbound(as: ByteBuffer.self) {
      let command = String(buffer: authData)
      let expected = "AUTH DBUS_COOKIE_SHA1 \(DBusAuthEncoding.hexEncode(userName))\r\n"
      #expect(command == expected, "Expected COOKIE_SHA1 auth with hex username")
    } else {
      #expect(Bool(false), "No COOKIE_SHA1 AUTH was sent")
    }

    let serverChallenge = "deadbeef"
    let serverData = "\(context) \(cookieId) \(serverChallenge)"
    let serverDataHex = DBusAuthEncoding.hexEncode(serverData)
    var dataBuffer = channel.allocator.buffer(capacity: serverDataHex.count + 16)
    dataBuffer.writeString("DATA \(serverDataHex)\r\n")
    try channel.writeInbound(dataBuffer)

    guard let responseBuffer = try channel.readOutbound(as: ByteBuffer.self) else {
      #expect(Bool(false), "No DATA response sent")
      return
    }
    let responseLine = String(buffer: responseBuffer)
    #expect(responseLine.hasPrefix("DATA "), "Expected DATA response")

    let responseHex = responseLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
    let decoded = try DBusAuthEncoding.decodeHexString(responseHex)
    let parts = decoded.split(whereSeparator: \.isWhitespace)
    guard parts.count == 2 else {
      #expect(Bool(false), "Expected client challenge and digest")
      return
    }

    let clientChallenge = String(parts[0])
    let digest = String(parts[1])
    let composite = "\(serverChallenge):\(clientChallenge):\(cookieValue)"
    let expectedDigest = Insecure.SHA1.hash(data: Array(composite.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    #expect(digest == expectedDigest, "Digest should match server challenge and cookie")

    try channel.close().wait()
  }

  @Test func completeAuthenticationCycle() throws {
    let channel = EmbeddedChannel()
    try DBusClient.addToPipeline(channel.pipeline, auth: .anonymous, enableUnixFDs: false)

    // Activate the channel (sends initial NUL byte + AUTH command)
    channel.pipeline.fireChannelActive()

    // Consume the outbound messages
    _ = try channel.readOutbound(as: ByteBuffer.self)
    _ = try channel.readOutbound(as: ByteBuffer.self)

    // Send OK response from server
    var okBuffer = channel.allocator.buffer(capacity: 16)
    okBuffer.writeString("OK 1234abcd5678ef90\r\n")
    try channel.writeInbound(okBuffer)

    // Verify BEGIN command was sent
    if let beginData = try channel.readOutbound(as: ByteBuffer.self) {
      let command = String(buffer: beginData)
      #expect(command == "BEGIN\r\n", "Expected BEGIN command after authentication")
    } else {
      #expect(Bool(false), "No BEGIN command was sent")
    }

    // Test that the handler is now forwarding messages
    // Create a proper DBusMessage instead of a raw ByteBuffer
    let testMessage = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 1,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/test/path"))),
        HeaderField(code: .interface, variant: DBusVariant(.string("org.test.Interface"))),
        HeaderField(code: .member, variant: DBusVariant(.string("TestMethod"))),
      ],
      body: []
    )

    try channel.writeAndFlush(testMessage).wait()

    // Message should be forwarded (not buffered)
    if let forwardedMessage = try channel.readOutbound(as: ByteBuffer.self) {
      // We can't directly compare the raw message, but we can check that something was sent
      #expect(forwardedMessage.readableBytes > 0, "Message should have been forwarded with content")
    } else {
      #expect(Bool(false), "No message was forwarded")
    }

    try channel.close().wait()
  }

  @Test func unixFdNegotiationCycle() throws {
    let channel = EmbeddedChannel()
    let logger = Logger(label: "dbus.test.auth")
    let handlers: [ChannelHandler] = [
      ByteToMessageHandler(LineBasedFrameDecoder()),
      DBusAuthenticationHandler(auth: .anonymous, enableUnixFDs: true, logger: logger),
      ByteToMessageHandler(DBusMessageDecoder(logger: logger)),
      MessageToByteHandler(DBusMessageEncoder(logger: logger)),
    ]
    try channel.pipeline.syncOperations.addHandlers(handlers)

    channel.pipeline.fireChannelActive()

    _ = try channel.readOutbound(as: ByteBuffer.self)
    _ = try channel.readOutbound(as: ByteBuffer.self)

    var okBuffer = channel.allocator.buffer(capacity: 32)
    okBuffer.writeString("OK 1234abcd5678ef90\r\n")
    try channel.writeInbound(okBuffer)

    if let negotiateData = try channel.readOutbound(as: ByteBuffer.self) {
      let command = String(buffer: negotiateData)
      #expect(command == "NEGOTIATE_UNIX_FD\r\n", "Expected NEGOTIATE_UNIX_FD command")
    } else {
      #expect(Bool(false), "No NEGOTIATE_UNIX_FD command was sent")
    }

    var agreeBuffer = channel.allocator.buffer(capacity: 20)
    agreeBuffer.writeString("AGREE_UNIX_FD\r\n")
    try channel.writeInbound(agreeBuffer)

    if let beginData = try channel.readOutbound(as: ByteBuffer.self) {
      let command = String(buffer: beginData)
      #expect(command == "BEGIN\r\n", "Expected BEGIN command after UNIX_FD negotiation")
    } else {
      #expect(Bool(false), "No BEGIN command was sent")
    }

    try channel.close().wait()
  }

  @Test func rejectedAuthenticationFallsBack() throws {
    let channel = EmbeddedChannel()

    try DBusClient.addToPipeline(channel.pipeline, auth: .anonymous, enableUnixFDs: false)

    // Activate the channel
    channel.pipeline.fireChannelActive()

    // Consume the outbound messages
    _ = try channel.readOutbound(as: ByteBuffer.self)
    _ = try channel.readOutbound(as: ByteBuffer.self)

    // Send REJECTED response
    var rejectedBuffer = channel.allocator.buffer(capacity: 32)
    rejectedBuffer.writeString("REJECTED EXTERNAL DBUS_COOKIE_SHA1\r\n")

    try channel.writeInbound(rejectedBuffer)

    // Expect fallback to another mechanism
    if let fallbackData = try channel.readOutbound(as: ByteBuffer.self) {
      let command = String(buffer: fallbackData)
      #expect(command.starts(with: "AUTH DBUS_COOKIE_SHA1"), "Expected COOKIE_SHA1 fallback")
    } else {
      #expect(Bool(false), "No fallback AUTH was sent")
    }

    // No BEGIN command should be sent yet
    #expect(
      try channel.readOutbound(as: ByteBuffer.self) == nil,
      "No BEGIN should be sent after fallback AUTH")

    try channel.close().wait()
  }

  @Test func channelWritabilityChanges() throws {
    let channel = EmbeddedChannel()

    // Add writability tracking handler
    var writabilityChangedBeforeAuth = false
    var writabilityChangedAfterAuth = false

    let writabilityTracker = WritabilityTracker(
      beforeAuthCallback: { writabilityChangedBeforeAuth = true },
      afterAuthCallback: { writabilityChangedAfterAuth = true }
    )
    try channel.pipeline.addHandler(writabilityTracker).wait()

    try DBusClient.addToPipeline(channel.pipeline, auth: .anonymous, enableUnixFDs: false)

    // Activate the channel
    channel.pipeline.fireChannelActive()

    // Consume the outbound messages
    _ = try channel.readOutbound(as: ByteBuffer.self)
    _ = try channel.readOutbound(as: ByteBuffer.self)

    // Trigger writability change before authentication
    channel.pipeline.fireChannelWritabilityChanged()

    // The beforeAuthCallback should be called, but event should not propagate
    #expect(
      writabilityChangedBeforeAuth == true, "Writability tracker should detect change before auth")

    // Complete authentication
    var okBuffer = channel.allocator.buffer(capacity: 16)
    okBuffer.writeString("OK 1234abcd5678ef90\r\n")
    try channel.writeInbound(okBuffer)

    // Consume the BEGIN command
    _ = try channel.readOutbound(as: ByteBuffer.self)

    // Trigger writability change after authentication
    channel.pipeline.fireChannelWritabilityChanged()

    // Event should propagate after auth
    #expect(writabilityChangedAfterAuth == true, "Writability change should propagate after auth")

    try channel.close().wait()
  }

  @Test func partialDataHandling() throws {
    let channel = EmbeddedChannel()
    try DBusClient.addToPipeline(channel.pipeline, auth: .anonymous, enableUnixFDs: false)

    // Activate the channel
    channel.pipeline.fireChannelActive()

    // Consume the outbound messages
    _ = try channel.readOutbound(as: ByteBuffer.self)
    _ = try channel.readOutbound(as: ByteBuffer.self)

    // Send first part of OK response
    var buffer1 = channel.allocator.buffer(capacity: 2)
    buffer1.writeString("OK")
    try channel.writeInbound(buffer1)

    // No BEGIN command should be sent yet (incomplete response)
    #expect(
      try channel.readOutbound(as: ByteBuffer.self) == nil,
      "No command should be sent for partial response")

    // Send the rest of the response
    var buffer2 = channel.allocator.buffer(capacity: 15)
    buffer2.writeString(" 1234abcd\r\n")
    try channel.writeInbound(buffer2)

    // Now the BEGIN command should be sent
    if let beginData = try channel.readOutbound(as: ByteBuffer.self) {
      let command = String(buffer: beginData)
      #expect(command == "BEGIN\r\n", "Expected BEGIN command after complete response")
    } else {
      #expect(Bool(false), "No BEGIN command was sent")
    }

    try channel.close().wait()
  }

}

// Helper handlers for testing
private final class WritabilityTracker: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  private let beforeAuthCallback: () -> Void
  private let afterAuthCallback: () -> Void
  private var authCompleted = false

  init(beforeAuthCallback: @escaping () -> Void, afterAuthCallback: @escaping () -> Void) {
    self.beforeAuthCallback = beforeAuthCallback
    self.afterAuthCallback = afterAuthCallback
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let buffer = self.unwrapInboundIn(data)

    // Check if this is an OK message from the server
    if let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes),
      str.starts(with: "OK ")
    {
      authCompleted = true
    }

    context.fireChannelRead(data)
  }

  func channelWritabilityChanged(context: ChannelHandlerContext) {
    if authCompleted {
      afterAuthCallback()
      context.fireChannelWritabilityChanged()
    } else {
      beforeAuthCallback()
      // Don't propagate the event before auth
    }
  }
}

// Make DBusAuthenticationError equatable for easier testing
extension DBusAuthenticationError {
  public static func == (lhs: DBusAuthenticationError, rhs: DBusAuthenticationError) -> Bool {
    switch (lhs, rhs) {
    case (.invalidInitialNull, .invalidInitialNull),
      (.invalidAuthCommand, .invalidAuthCommand),
      (.invalidBegin, .invalidBegin):
      return true
    default:
      return false
    }
  }
}
