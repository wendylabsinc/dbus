import Testing
@testable import DBusCodegen

@Suite
struct CodeWriterTests {
  @Test func writesSimpleLine() {
    var w = CodeWriter()
    w.writeLine("hello")
    #expect(w.result == "hello\n")
  }

  @Test func writesBlankLine() {
    var w = CodeWriter()
    w.writeLine("a")
    w.writeLine()
    w.writeLine("b")
    #expect(w.result == "a\n\nb\n")
  }

  @Test func writesIndentedBlock() {
    var w = CodeWriter()
    w.writeLine("outer {")
    w.indent {
      $0.writeLine("inner")
    }
    w.writeLine("}")
    #expect(w.result == "outer {\n    inner\n}\n")
  }

  @Test func writesNestedIndent() {
    var w = CodeWriter()
    w.indent {
      $0.writeLine("level1")
      $0.indent {
        $0.writeLine("level2")
      }
    }
    #expect(w.result == "    level1\n        level2\n")
  }

  @Test func blankLineHasNoIndent() {
    var w = CodeWriter()
    w.indent {
      $0.writeLine("a")
      $0.writeLine()
      $0.writeLine("b")
    }
    let lines = w.result.components(separatedBy: "\n")
    #expect(lines[1] == "")
  }

  @Test func writeMultipleLines() {
    var w = CodeWriter()
    w.writeLines(["a", "b", "c"])
    #expect(w.result == "a\nb\nc\n")
  }
}
