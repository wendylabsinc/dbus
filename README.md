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
- **Code Generation**: `.dbus.xml` introspection files generate type-safe Swift proxies at build time
- **Server-Side Export**: Export objects with methods/properties/signals (Introspectable, Properties, ObjectManager) and handle inbound calls
- **Type-Safe Interface**: Swift types mapped to D-Bus types with compile-time safety
- **SwiftNIO Foundation**: High-performance networking with proper resource management
- **Authentication Support**: ANONYMOUS and EXTERNAL authentication methods
- **Signal Subscriptions**: Receive D-Bus signals as Swift `AsyncStream`s
- **Comprehensive Testing**: Full test coverage with real-world scenarios

## Requirements

- Swift 6.0 or later

### Platform Support

DBUS is designed specifically for Linux environments where D-Bus is natively available. D-Bus is a core component of Linux desktop environments and is not natively supported on other platforms.

#### Docker Testing

For development and testing on non-Linux platforms, a Docker environment is provided:

```bash
./run-tests-in-docker.sh
```

## Installation

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
    dependencies: ["DBUS"]
),
```

---

## Code Generation with `.dbus.xml` Files

The recommended way to interact with a D-Bus service is to describe its interface in a `.dbus.xml` file and let the build-time plugin generate type-safe Swift proxies for you. This eliminates hand-written message construction and manual type casting.

### What is a `.dbus.xml` file?

A `.dbus.xml` file is a D-Bus introspection document that describes one or more D-Bus interfaces: their methods, properties, and signals. It follows the [standard D-Bus introspection format](https://dbus.freedesktop.org/doc/dbus-specification.html#introspection-format).

You can obtain an introspection document for any running service with `busctl`:

```bash
busctl introspect org.freedesktop.Avahi / org.freedesktop.Avahi.Server
busctl introspect org.bluez /org/bluez/hci0
```

Name your file `<something>.dbus.xml` and place it in your target's `Sources/` directory. The `DBusCodegenPlugin` will pick it up automatically at build time.

### XML Format

```xml
<node>
  <interface name="com.example.MyService">

    <!-- A method with one input arg and one output arg -->
    <method name="Echo">
      <arg name="message" type="s" direction="in"/>
      <arg name="reply"   type="s" direction="out"/>
    </method>

    <!-- A method with no arguments -->
    <method name="Reset"/>

    <!-- A read-only property -->
    <property name="Version" type="s" access="read"/>

    <!-- A read-write property -->
    <property name="Timeout" type="u" access="readwrite"/>

    <!-- A signal with arguments -->
    <signal name="ValueChanged">
      <arg name="newValue" type="s"/>
    </signal>

  </interface>
</node>
```

**Type signatures** follow the D-Bus specification — see the [type table](#d-bus-type-signatures) below.

### What gets generated

For every interface in the XML, the codegen produces:

| Generated symbol | Purpose |
|-----------------|---------|
| `protocol <Prefix>` | Client protocol — one `async throws` method per D-Bus method, `{ get async throws }` per readable property, and a signal subscription per signal |
| `struct <Prefix>Proxy: <Prefix>` | Concrete proxy that sends real D-Bus messages over a `DBusClient.Connection` |
| `protocol <Prefix>Handler` | Server protocol — implement this to expose the interface |
| `extension <Prefix>Handler { func makeInterface() }` | Builds a `DBusObjectServer.Interface` from your handler implementation |

The interface name `com.example.MyService` becomes the prefix `ComExampleMyService`, so you get `ComExampleMyServiceProxy` and `ComExampleMyServiceHandler`.

### Worked example: Avahi service browser

`Sources/AvahiBrowse/avahi.dbus.xml` describes two Avahi interfaces:

```xml
<node>
  <interface name="org.freedesktop.Avahi.Server">
    <method name="GetVersionString">
      <arg name="version" type="s" direction="out"/>
    </method>
    <method name="ServiceBrowserNew">
      <arg name="interface" type="i" direction="in"/>
      <arg name="protocol"  type="i" direction="in"/>
      <arg name="type"      type="s" direction="in"/>
      <arg name="domain"    type="s" direction="in"/>
      <arg name="flags"     type="u" direction="in"/>
      <arg name="browser"   type="o" direction="out"/>
    </method>
  </interface>

  <interface name="org.freedesktop.Avahi.ServiceBrowser">
    <signal name="ItemNew">
      <arg name="interface" type="i"/>
      <arg name="protocol"  type="i"/>
      <arg name="name"      type="s"/>
      <arg name="type"      type="s"/>
      <arg name="domain"    type="s"/>
      <arg name="flags"     type="u"/>
    </signal>
    <signal name="AllForNow"/>
    <signal name="Failure">
      <arg name="error" type="s"/>
    </signal>
  </interface>
</node>
```

The plugin generates (simplified):

```swift
// Generated by dbus-codegen. Do not edit.
import DBUS

// MARK: - org.freedesktop.Avahi.Server

public protocol OrgFreedesktopAvahiServer: Sendable {
    func getVersionString() async throws -> String
    func serviceBrowserNew(
        interface: Int32, protocol: Int32, type: String,
        domain: String, flags: UInt32
    ) async throws -> String   // returns an object path
}

public struct OrgFreedesktopAvahiServerProxy: OrgFreedesktopAvahiServer {
    // ... full implementation
}

// MARK: - org.freedesktop.Avahi.ServiceBrowser

public protocol OrgFreedesktopAvahiServiceBrowser: Sendable {
    func itemNew()    async throws -> AsyncStream<(interface: Int32, protocol: Int32, name: String, type: String, domain: String, flags: UInt32)>
    func allForNow()  async throws -> AsyncStream<Void>
    func failure()    async throws -> AsyncStream<String>
}

public struct OrgFreedesktopAvahiServiceBrowserProxy: OrgFreedesktopAvahiServiceBrowser {
    // ... full implementation
}
```

Using the proxies in application code:

```swift
try await DBusClient.withConnection(
    to: SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket"),
    auth: .external(userID: String(getuid()))
) { connection in
    let server = OrgFreedesktopAvahiServerProxy(
        connection: connection,
        destination: "org.freedesktop.Avahi",
        path: "/"
    )

    let version = try await server.getVersionString()
    print("Avahi \(version)")

    let browserPath = try await server.serviceBrowserNew(
        interface: -1, protocol: -1,
        type: "_http._tcp", domain: "", flags: 0
    )

    let browser = OrgFreedesktopAvahiServiceBrowserProxy(
        connection: connection,
        destination: "org.freedesktop.Avahi",
        path: browserPath
    )

    let newServices  = try await browser.itemNew()
    let done         = try await browser.allForNow()

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for await svc in newServices {
                print("  [+] \(svc.name).\(svc.type).\(svc.domain)")
            }
        }
        for await _ in done { break }
        group.cancelAll()
    }
}
```

### Worked example: BlueZ BLE scanner (properties + signals)

`Sources/BleScanner/bluez.dbus.xml` shows properties and the `ObjectManager` pattern:

```xml
<node>
  <interface name="org.bluez.Adapter1">
    <method name="StartDiscovery"/>
    <method name="StopDiscovery"/>
    <method name="SetDiscoveryFilter">
      <arg name="properties" type="a{sv}" direction="in"/>
    </method>
    <property name="Address"    type="s" access="read"/>
    <property name="Name"       type="s" access="read"/>
    <property name="Powered"    type="b" access="readwrite"/>
    <property name="Discovering" type="b" access="read"/>
  </interface>

  <interface name="org.freedesktop.DBus.ObjectManager">
    <method name="GetManagedObjects">
      <arg name="objects" type="a{oa{sa{sv}}}" direction="out"/>
    </method>
    <signal name="InterfacesAdded">
      <arg name="objectPath"  type="o"/>
      <arg name="interfaces"  type="a{sa{sv}}"/>
    </signal>
    <signal name="InterfacesRemoved">
      <arg name="objectPath"  type="o"/>
      <arg name="interfaces"  type="as"/>
    </signal>
  </interface>
</node>
```

Properties with `access="read"` become async computed properties on the proxy:

```swift
let adapter = OrgBluezAdapter1Proxy(
    connection: connection,
    destination: "org.bluez",
    path: "/org/bluez/hci0"
)

let name    = try await adapter.name       // calls org.freedesktop.DBus.Properties.Get
let address = try await adapter.address
try await adapter.setPowered(true)         // calls Properties.Set

try await adapter.startDiscovery()

let objectManager = OrgFreedesktopDBusObjectManagerProxy(
    connection: connection,
    destination: "org.bluez",
    path: "/"
)

// Subscribe to live device events as an AsyncStream
let appeared    = try await objectManager.interfacesAdded()
let disappeared = try await objectManager.interfacesRemoved()
```

### Enabling the plugin in Package.swift

Add `DBusCodegenPlugin` to the `plugins` list of any target that contains `.dbus.xml` files:

```swift
.executableTarget(
    name: "MyApp",
    dependencies: ["DBUS"],
    plugins: [.plugin(name: "DBusCodegenPlugin")]
),
.plugin(
    name: "DBusCodegenPlugin",
    capability: .buildTool(),
    dependencies: ["dbus-codegen"]
),
```

The plugin runs `dbus-codegen` for every `*.dbus.xml` file in the target and places the generated `.swift` files in the plugin work directory — they are compiled as part of the same module automatically.

### Using the `dbus-codegen` CLI directly

The code generator is also available as a standalone command-line tool for use outside of SwiftPM build plugins (e.g. in a CI pre-generation step):

```bash
# Generate next to the input file
swift run dbus-codegen myservice.dbus.xml

# Specify an output directory
swift run dbus-codegen --output-dir Sources/Generated myservice.dbus.xml

# Stamp the module name into the file header
swift run dbus-codegen --module-name MyApp myservice.dbus.xml

# Multiple files at once
swift run dbus-codegen bluez.dbus.xml avahi.dbus.xml --output-dir Sources/Generated
```

Output files are named after the input — `myservice.dbus.xml` → `myservice.dbus.swift`.

### Server-side: implementing a handler

For every interface the codegen also generates a `Handler` protocol and a `makeInterface()` extension so you can expose that interface over a `DBusObjectServer`:

Given `echo.dbus.xml`:
```xml
<node>
  <interface name="com.example.Echo">
    <method name="Ping">
      <arg name="message" type="s" direction="in"/>
      <arg name="reply"   type="s" direction="out"/>
    </method>
    <property name="Version" type="s" access="read"/>
  </interface>
</node>
```

The codegen produces:

```swift
public protocol ComExampleEchoHandler: Sendable {
    func ping(message: String) async throws -> String
    var version: String { get async throws }
}

extension ComExampleEchoHandler {
    public func makeInterface() -> DBusObjectServer.Interface { /* ... */ }
}
```

Implementing and exporting:

```swift
struct MyEchoHandler: ComExampleEchoHandler {
    func ping(message: String) async throws -> String { message }
    var version: String { "1.0.0" }
}

let server = DBusObjectServer(connection: connection)
let handler = MyEchoHandler()
await server.export(.init(path: "/com/example/Echo", interfaces: [handler.makeInterface()]))
```

---

## Low-Level API

You can also build messages manually without code generation.

### Connecting to D-Bus

```swift
import DBUS

try await DBusClient.withConnection(
    to: SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket"),
    auth: .external(userID: getuid())
) { connection in
    // connection is ready to use
}
```

Resolve addresses from environment variables or parse D-Bus address strings:

```swift
// Session bus from $DBUS_SESSION_BUS_ADDRESS
try await DBusClient.withSessionBus(auth: .external(userID: getuid())) { connection in }

// Parse and connect to an explicit address string
let address = try DBusAddress.parse("unix:path=/var/run/dbus/system_bus_socket")
try await DBusClient.withConnection(to: address, auth: .external(userID: getuid())) { connection in }
```

`DBusAddress` can also be constructed directly:

```swift
let address: DBusAddress = .tcp(host: "127.0.0.1", port: 1234, family: nil)
```

Supported address formats:
- `unix:path=/path/to/socket`
- `unix:abstract=socket_name` (Linux only)
- `tcp:host=127.0.0.1,port=1234` (optional `family=ipv4|ipv6`)
- `nonce-tcp:host=127.0.0.1,port=1234,noncefile=/path` — sends a 16-byte nonce before auth
- Multiple addresses separated by `;` — first supported entry is used

### Calling a Method

```swift
let reply = try await connection.send(DBusRequest.createMethodCall(
    destination: "org.freedesktop.DBus",
    path: "/org/freedesktop/DBus",
    interface: "org.freedesktop.DBus",
    method: "ListNames"
))

if let reply {
    print("Received reply: \(reply)")
}
```

### Sending a Signal

```swift
let signal = DBusRequest.createSignal(
    path: "/org/example/Path",
    interface: "org.example.Interface",
    name: "ExampleSignal"
)
try await connection.send(signal)
```

### Working with D-Bus Types

```swift
// D-Bus types are represented as DBusValue
let stringValue = DBusValue.string("Hello")
let intValue    = DBusValue.uint32(42)
let arrayValue  = DBusValue.array([stringValue, intValue])

// Pass typed arguments in a method call
let request = DBusRequest.createMethodCall(
    destination: "org.freedesktop.DBus",
    path: "/org/freedesktop/DBus",
    interface: "org.freedesktop.DBus",
    method: "GetConnectionUnixProcessID",
    body: [DBusValue.string("org.freedesktop.DBus")]
)
```

### Exporting Objects (server side)

Use `DBusObjectServer` to expose D-Bus objects, properties, and methods that other peers can call. The code-generated `makeInterface()` helper is the easiest way to do this; the manual API looks like:

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
// Now handles: Introspectable.Introspect, Properties.Get/GetAll, org.example.Echo.Ping
```

### BlueZ advertisement + GATT example

The `ExampleApp` target registers both a LE advertisement and a GATT tree with BlueZ:

1. Export objects:
   - `org.bluez.LEAdvertisement1` at `/com/wendylabs/example/adv0`
   - `org.bluez.GattApplication1` root with ObjectManager at `/com/wendylabs/example/gatt`
   - `org.bluez.GattService1` / `GattCharacteristic1` / `GattDescriptor1` child nodes
2. Call `RegisterAdvertisement` and `RegisterApplication` on `/org/bluez/hci0`.

```bash
swift run ExampleApp
```

Verify in another shell:

```bash
bluetoothctl show
busctl introspect org.bluez /com/wendylabs/example/adv0
busctl introspect org.bluez /com/wendylabs/example/gatt
```

See `Sources/ExampleApp/App.swift` for the full runnable template.

### Using Logging

DBUS logs to [swift-log](https://github.com/swiftlang/swift-log). Internal events are emitted at `.debug` and `.trace` levels.

---

## D-Bus Type Signatures

| D-Bus Type  | Signature | Swift Type (codegen) |
|-------------|-----------|----------------------|
| Byte        | `y`       | `UInt8`              |
| Boolean     | `b`       | `Bool`               |
| Int16       | `n`       | `Int16`              |
| UInt16      | `q`       | `UInt16`             |
| Int32       | `i`       | `Int32`              |
| UInt32      | `u`       | `UInt32`             |
| Int64       | `x`       | `Int64`              |
| UInt64      | `t`       | `UInt64`             |
| Double      | `d`       | `Double`             |
| String      | `s`       | `String`             |
| Object Path | `o`       | `String`             |
| Signature   | `g`       | `String`             |
| Unix FD     | `h`       | `UInt32`             |
| Variant     | `v`       | `DBusVariant`        |
| Byte array  | `ay`      | `[UInt8]`            |
| String array| `as`      | `[String]`           |
| Dict sv     | `a{sv}`   | `[String: DBusVariant]` |
| Dict ss     | `a{ss}`   | `[String: String]`   |
| Other       | anything  | `DBusValue`          |

For complex or deeply-nested types (e.g. `a{oa{sa{sv}}}`) the codegen falls back to `DBusValue` and you decode manually using pattern matching.

---

## Limitations and Missing Features

### Not Yet Implemented
- **Bus Name Management**: No automatic name reservation or ownership monitoring
- **Property Caching**: No change notifications or caching helpers
- **Connection Pooling**: Limited to single-use connections

### Known Issues
- Empty arrays default to byte array type signature regardless of intended type
- Complex nested dictionary structures may have parsing edge cases
- Authentication handler has potential race conditions

### Planned Features
- Higher-level convenience APIs
- Service registration capabilities
- Connection management improvements

---

## Testing

```bash
swift test
```

Tests run on Linux and include real-world scenarios with NetworkManager integration.

## License

This project is available under the Apache License 2.0. See the LICENSE file for more info.
