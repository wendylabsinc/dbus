public struct CodeWriter {
  private var output = ""
  private var indentLevel = 0
  private let indentString = "    "

  public init() {}

  public mutating func writeLine(_ line: String = "") {
    if line.isEmpty {
      output += "\n"
    } else {
      output += String(repeating: indentString, count: indentLevel) + line + "\n"
    }
  }

  public mutating func writeLines(_ lines: [String]) {
    for line in lines { writeLine(line) }
  }

  public mutating func indent(_ block: (inout CodeWriter) -> Void) {
    indentLevel += 1
    block(&self)
    indentLevel -= 1
  }

  public var result: String { output }
}
