/// Errors raised by the DBUS library during encoding, decoding, or transport.
public enum DBusError: Error {
  case earlyEOF
  case invalidByteOrder
  case invalidMessageType
  case invalidHeader
  case invalidBody
  case truncatedHeaderFields
  case invalidHeaderField
  case invalidString
  case invalidUTF8
  case invalidSignature
  case unsupportedType
  case missingReply
  case unexpectedMessageType
  case truncatedBody
  case unixFdNotNegotiated
  case unixFdMissing
  case unixFdControlTruncated
  case unixFdUnsupported
  case timeout
}
