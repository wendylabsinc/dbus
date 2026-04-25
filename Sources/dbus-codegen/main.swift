import DBusCodegen
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

func printUsage() {
  print(
    """
    Usage: dbus-codegen [--output-dir <dir>] [--module-name <name>] <file.dbus.xml> ...

    Options:
      --output-dir <dir>    Directory for generated .swift files (default: alongside input)
      --module-name <name>  Module name to stamp in the file header
    """)
}

var outputDir: String? = nil
var moduleName: String? = nil
var files: [String] = []

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
  let arg = args.removeFirst()
  switch arg {
  case "--output-dir":
    guard !args.isEmpty else {
      fputs("error: --output-dir requires a value\n", stderr)
      exit(1)
    }
    outputDir = args.removeFirst()
  case "--module-name":
    guard !args.isEmpty else {
      fputs("error: --module-name requires a value\n", stderr)
      exit(1)
    }
    moduleName = args.removeFirst()
  case "--help", "-h":
    printUsage()
    exit(0)
  default:
    if arg.hasPrefix("--") {
      fputs("error: unknown flag: \(arg)\n", stderr)
      exit(1)
    }
    files.append(arg)
  }
}

guard !files.isEmpty else {
  fputs("error: no input files specified\n", stderr)
  printUsage()
  exit(1)
}

var exitCode: Int32 = 0

for filePath in files {
  let url = URL(fileURLWithPath: filePath)
  let xml: String
  do {
    xml = try String(contentsOf: url, encoding: .utf8)
  } catch {
    fputs("error: cannot read \(filePath): \(error)\n", stderr)
    exitCode = 1
    continue
  }

  let generated: String
  do {
    generated = try Codegen.generate(xml: xml, moduleName: moduleName)
  } catch {
    fputs("error: \(filePath): \(error)\n", stderr)
    exitCode = 1
    continue
  }

  let outputName = url.lastPathComponent
    .replacingOccurrences(of: ".dbus.xml", with: ".dbus.swift")
    .replacingOccurrences(of: ".xml", with: ".swift")

  let outputURL: URL
  if let dir = outputDir {
    outputURL = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(outputName)
  } else {
    outputURL = url.deletingLastPathComponent().appendingPathComponent(outputName)
  }

  do {
    try generated.write(to: outputURL, atomically: true, encoding: .utf8)
    print("Generated: \(outputURL.path)")
  } catch {
    fputs("error: cannot write \(outputURL.path): \(error)\n", stderr)
    exitCode = 1
  }
}

exit(exitCode)
