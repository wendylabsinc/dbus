internal enum DBusSerialGenerator {
  static func next(after current: UInt32) -> UInt32 {
    var next = current &+ 1
    if next == 0 {
      next = 1
    }
    return next
  }
}
