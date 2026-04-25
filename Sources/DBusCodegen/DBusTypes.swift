// Placeholder types referenced by generated code and TypeMapper.
// These represent DBus wire types that generated code uses at runtime.

typealias DBusVariant = DBusValue
typealias DBusValue = Any

public enum DBusCodegenError: Error, Sendable {
  case typeMismatch
  case invalidSignature(String)
  case missingField(String)
}
