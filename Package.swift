// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "DBUS",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "DBUS", targets: ["DBUS"]),
    .library(name: "DBusCodegen", targets: ["DBusCodegen"]),
    .executable(name: "dbus-codegen", targets: ["dbus-codegen"]),
    .executable(name: "AvahiBrowse", targets: ["AvahiBrowse"]),
    .executable(name: "BleScanner", targets: ["BleScanner"]),
    .plugin(name: "DBusCodegenPlugin", targets: ["DBusCodegenPlugin"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.26.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    .package(url: "https://github.com/apple/swift-algorithms.git", from: "1.2.0"),
  ],
  targets: [
    .target(
      name: "DBUS",
      dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOExtras", package: "swift-nio-extras"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Algorithms", package: "swift-algorithms"),
      ]
    ),
    .target(name: "DBusCodegen"),
    .executableTarget(
      name: "dbus-codegen",
      dependencies: ["DBusCodegen"]
    ),
    .plugin(
      name: "DBusCodegenPlugin",
      capability: .buildTool(),
      dependencies: ["dbus-codegen"]
    ),
    .executableTarget(name: "ExampleApp", dependencies: ["DBUS"]),
    .executableTarget(
      name: "BleScanner",
      dependencies: [
        "DBUS",
        .product(name: "NIOCore", package: "swift-nio"),
      ],
      plugins: [.plugin(name: "DBusCodegenPlugin")]
    ),
    .executableTarget(
      name: "AvahiBrowse",
      dependencies: [
        "DBUS",
        .product(name: "NIOCore", package: "swift-nio"),
      ],
      plugins: [.plugin(name: "DBusCodegenPlugin")]
    ),
    .testTarget(
      name: "DBUSTests",
      dependencies: ["DBUS"]
    ),
    .testTarget(
      name: "DBusCodegenTests",
      dependencies: ["DBusCodegen"]
    ),
  ]
)
