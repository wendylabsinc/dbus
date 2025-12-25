# DBUS


[![Swift 6.0.0](https://img.shields.io/badge/Swift-6.0.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-Linux-green.svg)](https://swift.org)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://www.apache.org/licenses/LICENSE-2.0)
[![Linux](https://img.shields.io/github/actions/workflow/status/apache-edge/dbus/swift.yml?branch=main&label=Linux)](https://github.com/apache-edge/dbus/actions/workflows/swift.yml)

A Swift 6 D-Bus protocol implementation with SwiftNIO and modern Swift concurrency support.

## Overview

DBUS is a Swift package that provides a pure Swift implementation of the D-Bus protocol built on SwiftNIO. D-Bus is a message bus system used for interprocess communication on Linux systems. This library enables Swift applications to communicate with system services and other applications using modern Swift concurrency features.

## Features

- **Pure Swift Implementation**: No C library dependencies, built entirely on SwiftNIO
- **Modern Swift 6 API**: Full async/await support with Swift concurrency
- **Complete D-Bus Protocol**: Message parsing, authentication, and type system
- **Server-Side Export**: Export objects with methods/properties/signals (Introspectable, Properties, ObjectManager) and handle inbound calls
- **Type-Safe Interface**: Swift types mapped to D-Bus types with compile-time safety
- **SwiftNIO Foundation**: High-performance networking with proper resource management
- **Authentication Support**: ANONYMOUS and EXTERNAL authentication methods
- **Comprehensive Testing**: Full test coverage with real-world scenarios
- **Well Documented**: DocC comments and extensive usage examples

## Requirements

- Swift 6.0 or later

### Platform Support

DBUS is designed specifically for Linux environments where D-Bus is natively available. D-Bus is a core component of Linux desktop environments and is not natively supported on other platforms.

#### Docker Testing

For development and testing on non-Linux platforms, a Docker environment is provided:

```bash
# Run tests in Docker
./run-tests-in-docker.sh
```

This will build a Docker container with all necessary dependencies and run the test suite in a Linux environment.

## Installation

### Swift Package Manager

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/wendylabsinc/dbus.git", from: "0.1.0")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["DBUS"]),
```

## Usage

### Connecting to D-Bus

```swift
import DBUS

try await DBusClient.withConnection(
    to: SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket"),
    auth: .external(userID: getuid())
) { connection in
    // You've got a DBUS connection!
}
```

You can also resolve addresses from environment variables or parse D-Bus address strings:

```swift
// Resolve the session or system bus address from the environment.
try await DBusClient.withSessionBus(auth: .external(userID: getuid())) { connection in
    // Session bus connection.
}

// Parse a D-Bus address string and connect.
let address = try DBusAddress.parse("unix:path=/var/run/dbus/system_bus_socket")
try await DBusClient.withConnection(to: address, auth: .external(userID: getuid())) { connection in
    // Connected using a parsed address.
}
```

`DBusAddress.parse` returns a `DBusAddress` value that you can also construct directly:

```swift
let address: DBusAddress = .tcp(host: "127.0.0.1", port: 1234, family: nil)
```

Supported address formats:
- `unix:path=/path/to/socket`
- `unix:abstract=socket_name` (Linux only)
- `tcp:host=127.0.0.1,port=1234` (optional `family=ipv4|ipv6`)
- `nonce-tcp:host=127.0.0.1,port=1234,noncefile=/path` (optional `family=ipv4|ipv6`)
- Lists separated by `;` (first supported entry is used)

Notes:
- `nonce-tcp` requires a 16-byte nonce file; the nonce is sent before authentication.
- `tcp` hostnames resolve asynchronously during connect; prefer IP literals to avoid DNS.

### Calling a Method

```swift
try await DBusClient.withConnection(
    to: SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket"),
    auth: .external(userID: getuid())
) { connection in
    // Send a method call and get reply
    let reply = try await connection.send(DBusRequest.createMethodCall(
        destination: "org.freedesktop.DBus",
        path: "/org/freedesktop/DBus", 
        interface: "org.freedesktop.DBus",
        method: "ListNames"
    ))
    
    // Handle the reply
    if let reply = reply {
        print("Received reply: \(reply)")
    }
}
```

### Sending a Signal

```swift
try await DBusClient.withConnection(
    to: SocketAddress(unixDomainSocketPath: "/var/run/dbus/session_bus_socket"),
    auth: .external(userID: getuid())
) { connection in
    // Create and send a signal
    let signal = DBusRequest.createSignal(
        path: "/org/example/Path",
        interface: "org.example.Interface", 
        name: "ExampleSignal"
    )
    try await connection.send(signal)
}
```

### Working with D-Bus Types

```swift
// D-Bus types are represented as DBusValue
let stringValue = DBusValue.string("Hello")
let intValue = DBusValue.uint32(42)
let arrayValue = DBusValue.array([stringValue, intValue])

// Create requests with typed arguments
let request = DBusRequest.createMethodCall(
    destination: "org.freedesktop.DBus",
    path: "/org/freedesktop/DBus",
    interface: "org.freedesktop.DBus", 
    method: "GetConnectionUnixProcessID",
    body: [DBusValue.string("org.freedesktop.DBus")]
)
```

### Handling Errors

```swift
try await DBusClient.withConnection(
    to: SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket"),
    auth: .external(userID: "0") // root user
) { connection in
    // Send request
    let reply = try await connection.send(DBusRequest.createMethodCall(
        destination: "org.freedesktop.DBus",
        path: "/org/freedesktop/DBus",
        interface: "org.freedesktop.DBus",
        method: "Hello"
    ))

    guard 
        let helloReply = reply,
        case .methodReturn = helloReply.messageType
    else {
        print("No reply from Hello method call")
        return
    }

    print("Received reply from Hello method call \(helloReply)")
}
```

### Exporting Objects (server side)

Use `DBusObjectServer` to expose D-Bus objects, properties, and methods that other peers can call.

```swift
let server = DBusObjectServer(connection: connection)

var echo = DBusObjectServer.Interface(name: "org.example.Echo")
echo.methods = [
  .init(name: "Ping") { _ in [.string("Pong")] }
]
echo.properties = [
  .init(name: "Version", value: .string("1.0.0"))
]

await server.export(.init(path: "/org/example/Echo", interfaces: [echo]))
// The server now replies to:
// - org.freedesktop.DBus.Introspectable.Introspect
// - org.freedesktop.DBus.Properties.Get/GetAll
// - org.example.Echo.Ping
```

### BlueZ advertisement + GATT example

The `ExampleApp` target registers both a LE advertisement and a GATT tree with BlueZ on the system bus:

1. Export objects:
   - `org.bluez.LEAdvertisement1` at `/com/wendylabs/example/adv0`
   - `org.bluez.GattApplication1` root with ObjectManager at `/com/wendylabs/example/gatt`
   - `org.bluez.GattService1`/`GattCharacteristic1`/`GattDescriptor1` child nodes
2. Call `RegisterAdvertisement` and `RegisterApplication` on `/org/bluez/hci0`.

Run the example (as a user allowed on the system bus):
```bash
swift run ExampleApp
```

Verify in another shell:
```bash
bluetoothctl show
busctl introspect org.bluez /com/wendylabs/example/adv0
busctl introspect org.bluez /com/wendylabs/example/gatt
```

BlueZ will call back into the exported objects for `Release`, `ReadValue`, `WriteValue`, `GetManagedObjects`, and property reads. See `Sources/ExampleApp/App.swift` for a minimal, runnable template.

### Using Logging

DBUS logs to [swift-log](https://github.com/swiftlang/swift-log) to help with debugging and understanding internal operations. You can provide your own logger implementation or use the standard adapters. We'll log to `.debug` and `.trace` levels in compliant with [established standards](https://www.swift.org/documentation/server/guides/libraries/log-levels.html).

## D-Bus Type Signatures

DBUS maps D-Bus types to Swift types as follows:

| D-Bus Type | Signature | Swift Type |
|------------|-----------|------------|
| Byte       | y         | UInt8      |
| Boolean    | b         | Bool       |
| Int16      | n         | Int16      |
| UInt16     | q         | UInt16     |
| Int32      | i         | Int32      |
| UInt32     | u         | UInt32     |
| Int64      | x         | Int64      |
| UInt64     | t         | UInt64     |
| Double     | d         | Double     |
| String     | s         | String     |
| Object Path| o         | String     |
| Signature  | g         | String     |
| Array      | a         | [DBusValue]|
| Variant    | v         | DBusVariant|

## Limitations and Missing Features

While DBUS provides a solid foundation for D-Bus communication, some features are not yet implemented:

### **Not Yet Implemented**
- **Signal Subscription**: No built-in signal filtering and callback registration
- **Connection Pooling**: Limited to single-use connections
- **Automatic Proxy Generation**: No XML parsing or proxy generation for remote introspection
- **Bus Name Management**: No automatic name reservation or ownership monitoring
- **Property Caching**: No change notifications or caching helpers
- **High-Level API**: Currently requires low-level message construction
- **UNIX_FD Support (NIO Client)**: Use `DBusUnixFDClient` when passing file descriptors

### **Known Issues**
- Empty arrays default to byte array type signature regardless of intended type
- Complex nested dictionary structures may have parsing edge cases
- Authentication handler has potential race conditions

### **Planned Features**
Future releases may include:
- Higher-level convenience APIs
- Signal subscription and routing
- Service registration capabilities  
- Introspection and proxy generation
- Connection management improvements

## Testing

DBUS includes comprehensive tests using Swift Testing. The tests are designed to run on Linux and include real-world scenarios with NetworkManager integration.

### Running Tests

```bash
swift test
```

## License

This project is available under the Apache License 2.0. See the LICENSE file for more info.
