#if canImport(Glibc)
import Glibc
import NIOCore
import Testing

@testable import DBUS

@Suite
struct UnixFDSocketTests {
  @Test func sendAndReceiveUnixFd() throws {
    var socketFds = [CInt](repeating: 0, count: 2)
    #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &socketFds) == 0)

    let sender = UnixFDSocket(fd: socketFds[0])
    var receiver = UnixFDSocket(fd: socketFds[1])

    var pipeFds = [CInt](repeating: 0, count: 2)
    #expect(pipe(&pipeFds) == 0)

    let readFd = pipeFds[0]
    let writeFd = pipeFds[1]

    let message = DBusMessage(
      byteOrder: .little,
      messageType: .methodCall,
      flags: [],
      protocolVersion: 1,
      serial: 1,
      headerFields: [
        HeaderField(code: .path, variant: DBusVariant(.objectPath("/org/example/Test"))),
        HeaderField(code: .interface, variant: DBusVariant(.string("org.example.Test"))),
        HeaderField(code: .member, variant: DBusVariant(.string("WithFd"))),
        HeaderField(code: .signature, variant: DBusVariant(.signature("h"))),
      ],
      body: [.unixFd(0)],
      unixFds: [readFd]
    )

    try sender.sendMessage(message, unixFdsEnabled: true)

    var buffer = ByteBufferAllocator().buffer(capacity: 0)
    var fdQueue: [CInt] = []
    guard let received = try receiver.receiveMessage(buffer: &buffer, fdQueue: &fdQueue) else {
      #expect(Bool(false), "Expected to receive a message")
      return
    }

    #expect(received.unixFds.count == 1)
    let receivedFd = received.unixFds[0]

    let payload: [UInt8] = [72, 73]
    _ = payload.withUnsafeBytes { rawBuffer in
      Glibc.write(writeFd, rawBuffer.baseAddress, payload.count)
    }

    var readBuffer = [UInt8](repeating: 0, count: payload.count)
    let readCount = Glibc.read(receivedFd, &readBuffer, readBuffer.count)
    #expect(readCount == payload.count)
    #expect(readBuffer == payload)

    _ = Glibc.close(receivedFd)
    _ = Glibc.close(readFd)
    _ = Glibc.close(writeFd)
    sender.close()
    receiver.close()
  }
}
#endif
