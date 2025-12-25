#if canImport(Glibc)
import Foundation
import Glibc
import NIOCore

struct UnixFDSocket: Sendable {
  let fd: CInt

  static func connect(to address: SocketAddress) throws -> UnixFDSocket {
    guard address.protocol == .unix else {
      throw DBusError.unixFdUnsupported
    }

    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    if fd < 0 {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    do {
      try address.withSockAddr { ptr, size in
        if Glibc.connect(fd, ptr, socklen_t(size)) != 0 {
          throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
      }
    } catch {
      _ = Glibc.close(fd)
      throw error
    }

    return UnixFDSocket(fd: fd)
  }

  func close() {
    _ = Glibc.close(fd)
  }

  func sendMessage(_ message: DBusMessage, unixFdsEnabled: Bool) throws {
    try message.validate(allowUnixFds: unixFdsEnabled, unixFdsError: .unixFdNotNegotiated)

    var buffer = ByteBuffer()
    message.write(to: &buffer)
    let bytes = Array(buffer.readableBytesView)
    try sendAll(bytes: bytes, fds: message.unixFds)
  }

  mutating func receiveMessage(
    buffer: inout ByteBuffer,
    fdQueue: inout [CInt]
  ) throws -> DBusMessage? {
    while true {
      if let message = try decodeMessage(buffer: &buffer, fdQueue: &fdQueue) {
        return message
      }

      let bytesRead = try recvChunk(buffer: &buffer, fdQueue: &fdQueue)
      if bytesRead == 0 {
        return nil
      }
    }
  }

  private func sendAll(bytes: [UInt8], fds: [CInt]) throws {
    var offset = 0
    var pendingFds = fds

    while offset < bytes.count {
      let remaining = bytes.count - offset
      let written = try bytes.withUnsafeBytes { rawBuffer in
        let base = rawBuffer.baseAddress!.advanced(by: offset)
        let slice = UnsafeRawBufferPointer(start: base, count: remaining)
        return try sendChunk(bytes: slice, fds: pendingFds)
      }

      if written == 0 {
        throw POSIXError(POSIXErrorCode.EPIPE)
      }
      offset += written
      pendingFds.removeAll(keepingCapacity: true)
    }
  }

  private func sendChunk(bytes: UnsafeRawBufferPointer, fds: [CInt]) throws -> Int {
    var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: bytes.baseAddress), iov_len: bytes.count)
    var msg = msghdr()
    msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
    msg.msg_iovlen = 1

    if fds.isEmpty {
      msg.msg_control = nil
      msg.msg_controllen = 0
      let result = Glibc.sendmsg(fd, &msg, 0)
      if result < 0 {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      return result
    }

    let dataLen = MemoryLayout<CInt>.stride * fds.count
    let controlLen = cmsgSpace(dataLen)
    var controlBuffer = [UInt8](repeating: 0, count: controlLen)

    return try controlBuffer.withUnsafeMutableBytes { controlBytes in
      msg.msg_control = controlBytes.baseAddress
      msg.msg_controllen = controlBytes.count

      guard let cmsg = cmsgFirstHeader(&msg) else {
        throw POSIXError(.EIO)
      }
      cmsg.pointee.cmsg_level = CInt(SOL_SOCKET)
      cmsg.pointee.cmsg_type = CInt(SCM_RIGHTS)
      cmsg.pointee.cmsg_len = cmsgLen(dataLen)

      let dataPtr = cmsgData(cmsg)
      fds.withUnsafeBytes { fdBytes in
        guard let base = fdBytes.baseAddress else { return }
        memcpy(dataPtr, base, dataLen)
      }

      let result = Glibc.sendmsg(fd, &msg, 0)
      if result < 0 {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      return result
    }
  }

  private mutating func recvChunk(buffer: inout ByteBuffer, fdQueue: inout [CInt]) throws -> Int {
    var dataBuffer = [UInt8](repeating: 0, count: 8192)
    var controlBuffer = [UInt8](repeating: 0, count: 4096)

    let bytesRead = try dataBuffer.withUnsafeMutableBytes { dataBytes -> Int in
      return try controlBuffer.withUnsafeMutableBytes { controlBytes -> Int in
        var iov = iovec(iov_base: dataBytes.baseAddress, iov_len: dataBytes.count)
        var msg = msghdr()
        msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
        msg.msg_iovlen = 1
        msg.msg_control = controlBytes.baseAddress
        msg.msg_controllen = controlBytes.count

        let result = Glibc.recvmsg(fd, &msg, 0)
        if result < 0 {
          throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if result == 0 {
          return 0
        }

        if (msg.msg_flags & CInt(MSG_CTRUNC)) != 0 {
          throw DBusError.unixFdControlTruncated
        }

        var cmsgPointer = cmsgFirstHeader(&msg)
        while let cmsg = cmsgPointer {
          if cmsg.pointee.cmsg_level == SOL_SOCKET && cmsg.pointee.cmsg_type == SCM_RIGHTS {
            let dataLen = Int(cmsg.pointee.cmsg_len) - cmsgLen(0)
            let count = dataLen / MemoryLayout<CInt>.stride
            let dataPtr = cmsgData(cmsg)
            let fdPtr = dataPtr.bindMemory(to: CInt.self, capacity: count)
            for index in 0..<count {
              fdQueue.append(fdPtr[index])
            }
          }
          cmsgPointer = cmsgNextHeader(&msg, cmsg)
        }

        return result
      }
    }

    if bytesRead > 0 {
      buffer.writeBytes(dataBuffer.prefix(bytesRead))
    }
    return bytesRead
  }

  private func decodeMessage(
    buffer: inout ByteBuffer,
    fdQueue: inout [CInt]
  ) throws -> DBusMessage? {
    let startIndex = buffer.readerIndex
    do {
      var message = try DBusMessage(from: &buffer)
      if let unixFdsCount = message.unixFdsCount, unixFdsCount > 0 {
        let count = Int(unixFdsCount)
        guard fdQueue.count >= count else {
          throw DBusError.unixFdMissing
        }
        message.unixFds = Array(fdQueue.prefix(count))
        fdQueue.removeFirst(count)
      }
      return message
    } catch DBusError.truncatedHeaderFields, DBusError.truncatedBody, DBusError.earlyEOF {
      buffer.moveReaderIndex(to: startIndex)
      return nil
    }
  }
}

private func cmsgAlign(_ length: Int) -> Int {
  let alignment = MemoryLayout<size_t>.size - 1
  return (length + alignment) & ~alignment
}

private func cmsgSpace(_ length: Int) -> Int {
  cmsgAlign(length) + cmsgAlign(MemoryLayout<cmsghdr>.size)
}

private func cmsgLen(_ length: Int) -> Int {
  cmsgAlign(MemoryLayout<cmsghdr>.size) + length
}

private func cmsgData(_ cmsg: UnsafeMutablePointer<cmsghdr>) -> UnsafeMutableRawPointer {
  UnsafeMutableRawPointer(cmsg).advanced(by: cmsgAlign(MemoryLayout<cmsghdr>.size))
}

private func cmsgFirstHeader(_ msg: UnsafeMutablePointer<msghdr>) -> UnsafeMutablePointer<cmsghdr>? {
  guard msg.pointee.msg_controllen >= cmsgLen(0) else { return nil }
  guard let base = msg.pointee.msg_control else { return nil }
  return base.assumingMemoryBound(to: cmsghdr.self)
}

private func cmsgNextHeader(
  _ msg: UnsafeMutablePointer<msghdr>,
  _ cmsg: UnsafeMutablePointer<cmsghdr>
) -> UnsafeMutablePointer<cmsghdr>? {
  guard let base = msg.pointee.msg_control else { return nil }
  let next = UnsafeMutableRawPointer(cmsg).advanced(by: cmsgAlign(Int(cmsg.pointee.cmsg_len)))
  let max = base.advanced(by: msg.pointee.msg_controllen)
  if next + MemoryLayout<cmsghdr>.size > max {
    return nil
  }
  return next.assumingMemoryBound(to: cmsghdr.self)
}
#endif
