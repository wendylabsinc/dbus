import Algorithms
import Logging
import NIO
import NIOCore
import NIOExtras

#if canImport(FoundationEssentials)
  import FoundationEssentials
#elseif canImport(Foundation)
  import Foundation
#endif

extension StringProtocol {
  /// Returns the string with leading and trailing whitespace and newlines removed.
  func trimmingWhitespaces() -> String {
    String(self.trimming(while: \.isWhitespace))
  }
}

/// Authentication types supported for D-Bus connections.
///
/// D-Bus supports several authentication mechanisms. This library currently implements
/// ANONYMOUS and EXTERNAL authentication methods.
///
/// ## Overview
///
/// Authentication is the first step when establishing a D-Bus connection. The client and server
/// negotiate which authentication mechanism to use before any D-Bus messages can be exchanged.
///
/// ## Supported Authentication Types
///
/// - **Anonymous**: No credentials are required. This is typically used for session buses
///   or when security is handled at a different layer.
/// - **External**: Uses the process's user ID for authentication. This is commonly used
///   for system buses where the operating system has already authenticated the user.
///
/// ## Example
/// ```swift
/// // Anonymous authentication
/// let client = try await DBusClient.withConnection(to: address, auth: .anonymous) { ... }
///
/// // External authentication with current user ID
/// let userID = String(getuid())
/// let client = try await DBusClient.withConnection(to: address, auth: .external(userID: userID)) { ... }
/// ```
///
/// - SeeAlso: [D-Bus Authentication Mechanisms](https://dbus.freedesktop.org/doc/dbus-specification.html#auth-mechanisms)
public struct AuthType: Sendable {
  internal enum Backing: Sendable {
    /// Anonymous authentication (no credentials)
    /// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-mechanisms-anonymous
    case anonymous

    /// External authentication using provided user ID
    /// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-mechanisms-external
    case external(userID: String)
  }

  let backing: Backing

  /// Anonymous authentication that requires no credentials.
  ///
  /// This authentication method is typically used for:
  /// - Session buses where all processes belong to the same user
  /// - Test environments
  /// - Situations where security is handled at a different layer
  ///
  /// - SeeAlso: [D-Bus ANONYMOUS Authentication](https://dbus.freedesktop.org/doc/dbus-specification.html#auth-mechanisms-anonymous)
  public static let anonymous = AuthType(backing: .anonymous)

  /// External authentication using a provided user ID.
  ///
  /// This authentication method uses the operating system's user ID to authenticate
  /// the connection. It's commonly used for system buses where the OS has already
  /// authenticated the user.
  ///
  /// - Parameter userID: The user ID to use for authentication, typically obtained from `getuid()`.
  /// - Returns: An `AuthType` configured for external authentication.
  ///
  /// ## Example
  /// ```swift
  /// import Foundation
  ///
  /// let userID = String(getuid())
  /// let auth = AuthType.external(userID: userID)
  /// ```
  ///
  /// - SeeAlso: [D-Bus EXTERNAL Authentication](https://dbus.freedesktop.org/doc/dbus-specification.html#auth-mechanisms-external)
  public static func external(userID: String) -> AuthType {
    AuthType(backing: .external(userID: userID))
  }
}

/// Handles the DBus authentication protocol
/// This channel handler implements the client-side of the DBus authentication protocol
/// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-protocol
internal final class DBusAuthenticationHandler: ChannelDuplexHandler, @unchecked Sendable {
  internal typealias InboundIn = ByteBuffer
  internal typealias InboundOut = ByteBuffer
  internal typealias OutboundIn = ByteBuffer
  internal typealias OutboundOut = ByteBuffer

  /// States of the DBus authentication protocol
  /// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-protocol
  internal enum State {
    /// Waiting for NUL byte reply from server (initial state)
    case waitingForNullReply
    /// Authentication sent, waiting for OK response
    case waitingForOK
    /// Waiting for UNIX FD negotiation response
    case waitingForUnixFdsAgreement
    /// Successfully authenticated, normal message passing can begin
    case authenticated
    /// Authentication failed
    case failed
  }

  private var state: State = .waitingForNullReply
  private var buffer = ByteBufferAllocator().buffer(capacity: 128)
  private let auth: AuthType
  private let enableUnixFDs: Bool
  private let initialBytes: [UInt8]
  private var unixFdsNegotiated = false
  private let logger: Logger
  private var writeBuffer = [ByteBuffer]()
  private var pendingMechanisms: [DBusAuthMechanism]
  private var currentMechanism: DBusAuthMechanism?

  internal init(
    auth: AuthType,
    enableUnixFDs: Bool,
    initialBytes: [UInt8] = [],
    logger: Logger
  ) {
    self.auth = auth
    self.enableUnixFDs = enableUnixFDs
    self.initialBytes = initialBytes
    self.logger = logger
    self.pendingMechanisms = DBusAuthMechanism.preferred(for: auth)
  }

  internal func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buf = self.unwrapInboundIn(data)
    buffer.writeBuffer(&buf)
    processBuffer(context: context)
  }

  private func processBuffer(context: ChannelHandlerContext) {
    defer { buffer.discardReadBytes() }
    while buffer.readableBytes > 0 {
      switch state {
      case .waitingForNullReply:
        // Wait for server's NUL byte reply (optional, but some servers send it)
        if let byte = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self), byte == 0 {
          buffer.moveReaderIndex(forwardBy: 1)
          logger.trace("Received initial NUL byte from server")
        }

        state = .waitingForOK
        logger.debug("Waiting for authentication response from server")
      case .waitingForOK:
        guard var line = readLine() else { return }
        logger.trace(
          "Received authentication response",
          metadata: [
            "response": "\(line.trimmingWhitespaces())"
          ]
        )

        if line.starts(with: "DATA ") {
          guard let currentMechanism else {
            state = .failed
            context.fireErrorCaught(DBusAuthenticationError.invalidAuthCommand)
            return
          }
          let payload = String(line.dropFirst(5)).trimmedWhitespace
          do {
            let response = try currentMechanism.cookieResponse(for: payload)
            let out = context.channel.allocator.buffer(string: response)
            context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)
          } catch {
            state = .failed
            context.fireErrorCaught(error)
          }
          return
        }

        if line.starts(with: "OK ") {
          line = String(line.dropFirst(3))
          if enableUnixFDs {
            logger.debug("Authentication successful, negotiating UNIX_FD support")
            let negotiate = "NEGOTIATE_UNIX_FD\r\n"
            let out = context.channel.allocator.buffer(string: negotiate)
            context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)
            state = .waitingForUnixFdsAgreement
          } else {
            logger.debug("Authentication successful, sending BEGIN command")
            completeAuthentication(context: context)
          }
        } else if line.starts(with: "REJECTED") {
          let trimmed = line.dropFirst("REJECTED".count)
            .trimmedWhitespace
          let offered = trimmed.isEmpty ? nil : Set(trimmed.split(separator: " ").map(String.init))
          handleRejected(offered: offered, context: context, rawLine: line)
        } else if line.starts(with: "ERROR") {
          handleRejected(offered: nil, context: context, rawLine: line)
        } else {
          logger.debug(
            "Received unexpected authentication response",
            metadata: [
              "response": "\(line.trimmingWhitespaces())"
            ]
          )
          state = .failed
          context.fireErrorCaught(DBusAuthenticationError.invalidAuthCommand)
          return
        }
      case .waitingForUnixFdsAgreement:
        guard let line = readLine() else { return }
        logger.trace(
          "Received UNIX_FD negotiation response",
          metadata: [
            "response": "\(line.trimmingWhitespaces())"
          ]
        )

        if line.starts(with: "AGREE_UNIX_FD") {
          unixFdsNegotiated = true
          logger.debug("UNIX_FD negotiation successful, sending BEGIN command")
          completeAuthentication(context: context)
        } else if line.starts(with: "ERROR") {
          unixFdsNegotiated = false
          logger.debug("UNIX_FD negotiation rejected, proceeding without FD support")
          completeAuthentication(context: context)
        } else {
          logger.debug(
            "Received unexpected UNIX_FD negotiation response",
            metadata: [
              "response": "\(line.trimmingWhitespaces())"
            ]
          )
          state = .failed
          context.fireErrorCaught(DBusAuthenticationError.invalidAuthCommand)
          return
        }
      case .authenticated:
        if buffer.readableBytes > 0 {
          logger.debug(
            "DBusAuthenticationHandler forwarding \(buffer.readableBytes) bytes to decoder")
          let pass = buffer.readSlice(length: buffer.readableBytes)!
          buffer.discardReadBytes()
          context.fireChannelRead(self.wrapInboundOut(pass))
        }
      case .failed:
        // Drop all data
        buffer.clear()
        context.close(promise: nil)
      }
    }
  }

  private func readLine() -> String? {
    let newline: UInt8 = 10
    guard let newlineIndex = buffer.readableBytesView.firstIndex(of: newline) else {
      guard buffer.readableBytes > 0 else { return nil }
      return buffer.readString(length: buffer.readableBytes)
    }
    let length = buffer.readableBytesView.distance(
      from: buffer.readableBytesView.startIndex,
      to: newlineIndex
    )
    guard var line = buffer.readString(length: length) else { return nil }
    buffer.moveReaderIndex(forwardBy: 1)
    if line.hasSuffix("\r") {
      line.removeLast()
    }
    return line
  }

  private func completeAuthentication(context: ChannelHandlerContext) {
    let begin = "BEGIN\r\n"
    let out = context.channel.allocator.buffer(string: begin)
    context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)

    do {
      let handler = try context.pipeline.syncOperations.handler(
        type: ByteToMessageHandler<LineBasedFrameDecoder>.self)
      _ = context.pipeline.syncOperations.removeHandler(handler)
      logger.debug("Removed LineBasedFrameDecoder from pipeline")

      for buffer in self.writeBuffer {
        logger.trace("Flushing buffered write", metadata: ["bytes": "\(buffer.readableBytes)"])
        context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
      }
      self.writeBuffer.removeAll(keepingCapacity: true)
      self.state = .authenticated
      logger.debug("D-Bus authentication completed successfully - now in message mode")

      // Check remaining buffered data
      if buffer.readableBytes > 0 {
        logger.debug("Processing \(buffer.readableBytes) buffered bytes after auth completion")
      }

      context.fireChannelActive()
      context.fireChannelWritabilityChanged()
      logger.debug("Fired channelActive and channelWritabilityChanged events")
    } catch {
      logger.warning(
        "Failed to complete authentication setup",
        metadata: [
          "error": "\(error)"
        ])
      context.fireErrorCaught(error)
    }
  }

  private func handleRejected(
    offered: Set<String>?,
    context: ChannelHandlerContext,
    rawLine: String
  ) {
    if let next = nextMechanism(allowed: offered) {
      logger.debug(
        "Authentication rejected by server, retrying",
        metadata: [
          "mechanism": "\(next.name)"
        ])
      sendAuth(for: next, context: context)
    } else {
      let trimmed = rawLine.trimmingWhitespaces()
      logger.debug(
        "Authentication rejected by server with no supported mechanisms",
        metadata: [
          "response": "\(trimmed)"
        ])
      state = .failed
      context.fireErrorCaught(DBusAuthenticationError.invalidAuthCommand)
    }
  }

  private func nextMechanism(allowed: Set<String>?) -> DBusAuthMechanism? {
    while let candidate = pendingMechanisms.first {
      pendingMechanisms.removeFirst()
      if let allowed, !allowed.contains(candidate.name) {
        continue
      }
      currentMechanism = candidate
      return candidate
    }
    return nil
  }

  private func sendAuth(for mechanism: DBusAuthMechanism, context: ChannelHandlerContext) {
    do {
      let authLine = try mechanism.authLine()
      let out = context.channel.allocator.buffer(string: authLine)
      context.writeAndFlush(self.wrapOutboundOut(out), promise: nil)
      logger.trace(
        "Sending authentication command",
        metadata: [
          "command": "\(authLine.trimmingWhitespaces())"
        ]
      )
    } catch {
      state = .failed
      context.fireErrorCaught(error)
    }
  }

  internal func write(
    context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?
  ) {
    if state == .authenticated, writeBuffer.isEmpty {
      context.writeAndFlush(data, promise: promise)
    } else {
      writeBuffer.append(self.unwrapOutboundIn(data))
    }
  }

  internal func channelWritabilityChanged(context: ChannelHandlerContext) {
    if state == .authenticated {
      context.fireChannelWritabilityChanged()
    }
  }

  /// Initiates the DBus authentication process when the channel becomes active
  /// Sends the initial NUL byte followed by the AUTH command
  /// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-command
  internal func channelActive(context: ChannelHandlerContext) {
    logger.debug("Starting D-Bus authentication")

    // Send initial NUL byte and AUTH command
    var buf = context.channel.allocator.buffer(capacity: max(64, initialBytes.count + 1))
    if !initialBytes.isEmpty {
      buf.writeBytes(initialBytes)
    }
    buf.writeInteger(UInt8(0))
    context.writeAndFlush(self.wrapOutboundOut(buf), promise: nil)

    guard let mechanism = nextMechanism(allowed: nil) else {
      state = .failed
      context.fireErrorCaught(DBusAuthenticationError.invalidAuthCommand)
      return
    }
    sendAuth(for: mechanism, context: context)
  }
}

/// Errors that can occur during the DBus authentication process
/// See: https://dbus.freedesktop.org/doc/dbus-specification.html#auth-protocol
public enum DBusAuthenticationError: Error {
  /// The initial NUL byte was invalid or missing
  case invalidInitialNull
  /// Received an invalid AUTH command response
  case invalidAuthCommand
  /// The BEGIN command failed
  case invalidBegin
}

/// Events that can be triggered during the DBus authentication process
enum DBusAuthenticationEvent {
  /// Authentication was successful
  case authenticated
}
