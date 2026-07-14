// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "linkage-test",
  dependencies: [
    .package(name: "DBUS", path: "../..")
  ],
  targets: [
    .executableTarget(
      name: "linkageTest",
      dependencies: [
        .product(name: "DBUS", package: "DBUS")
      ]
    )
  ]
)
