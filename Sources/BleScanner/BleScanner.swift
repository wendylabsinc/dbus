import DBUS
import Logging
import NIOCore

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#elseif canImport(Musl)
  import Musl
#endif

// bluez.dbus.swift is generated from bluez.dbus.xml by DBusCodegenPlugin.
// It provides: OrgBluezAdapter1Proxy, OrgFreedesktopDBusObjectManagerProxy

@main
struct BleScanner {
  static func main() async throws {
    var logger = Logger(label: "ble.scanner")
    logger.logLevel = .warning  // suppress DBUS noise

    let systemSocket = try SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket")
    let uid = String(getuid())

    try await DBusClient.withConnection(
      to: systemSocket,
      auth: .external(userID: uid),
      logger: logger
    ) { connection in
      let adapter = OrgBluezAdapter1Proxy(
        connection: connection,
        destination: "org.bluez",
        path: "/org/bluez/hci0"
      )
      let objectManager = OrgFreedesktopDBusObjectManagerProxy(
        connection: connection,
        destination: "org.bluez",
        path: "/"
      )

      // ── Adapter info ───────────────────────────────────────────────────────
      let adapterAddress = try await adapter.address
      let adapterName = try await adapter.name
      print("Adapter: \(adapterName) [\(adapterAddress)]")

      // ── Already-known devices ─────────────────────────────────────────────
      // GetManagedObjects returns a{oa{sa{sv}}} → DBusValue.
      // We decode it manually since it's a deeply nested BlueZ-specific structure.
      let managed = try await objectManager.getManagedObjects()
      let known = devices(in: managed)
      if known.isEmpty {
        print("No cached devices.")
      } else {
        print("\nCached devices:")
        for dev in known { printDevice(dev) }
      }

      // ── Subscribe to live events before starting discovery ─────────────────
      // Subscribe first so we don't miss signals emitted during StartDiscovery.
      let appeared = try await objectManager.interfacesAdded()
      let disappeared = try await objectManager.interfacesRemoved()

      // ── Start discovery ────────────────────────────────────────────────────
      try await adapter.startDiscovery()
      print("\nScanning for 10 s…\n")

      // Run the signal listeners and a 10-second timer as sibling tasks.
      // group.next() returns when the first task finishes (the timer),
      // then cancelAll() stops the signal listeners.
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await event in appeared {
            guard let dev = device(path: event.objectPath, interfaces: event.interfaces) else {
              continue
            }
            print("  +", terminator: " ")
            printDevice(dev)
          }
        }
        group.addTask {
          for await event in disappeared {
            guard event.objectPath.contains("/dev_") else { continue }
            print("  - \(event.objectPath)")
          }
        }
        group.addTask {
          try? await Task.sleep(for: .seconds(10))
        }
        _ = await group.next()  // wait for timer task
        group.cancelAll()
      }

      try await adapter.stopDiscovery()
      print("\nScan complete.")
    }
  }
}

// ── Decoding helpers ───────────────────────────────────────────────────────────

struct DeviceInfo {
  let path: String
  let address: String
  let name: String?
  let rssi: Int?
}

func printDevice(_ dev: DeviceInfo) {
  var line = "\(dev.address)  \(dev.name ?? "(unnamed)")"
  if let rssi = dev.rssi { line += "  \(rssi) dBm" }
  print(line)
}

/// Extract all `org.bluez.Device1` entries from a GetManagedObjects reply.
func devices(in value: DBusValue) -> [DeviceInfo] {
  guard case .dictionary(let objects) = value else { return [] }
  return objects.compactMap { pathVal, ifacesVal in
    device(path: pathVal, interfaces: ifacesVal)
  }
}

/// Try to build a DeviceInfo from a single InterfacesAdded event payload.
func device(path: String, interfaces: DBusValue) -> DeviceInfo? {
  guard path.contains("/dev_"),
    case .dictionary(let ifaces) = interfaces,
    let propsVal = ifaces[.string("org.bluez.Device1")],
    case .dictionary(let props) = propsVal
  else { return nil }
  return DeviceInfo(
    path: path,
    address: variantString(props, "Address") ?? "??:??:??:??:??:??",
    name: variantString(props, "Name"),
    rssi: variantInt16(props, "RSSI").map(Int.init)
  )
}

/// Try to build a DeviceInfo from a raw objectPath DBusValue + interfaces DBusValue.
/// Used when iterating GetManagedObjects which uses .objectPath keys.
func device(path: DBusValue, interfaces: DBusValue) -> DeviceInfo? {
  guard case .objectPath(let p) = path else { return nil }
  return device(path: p, interfaces: interfaces)
}

func variantString(_ props: [DBusValue: DBusValue], _ key: String) -> String? {
  guard case .variant(let v) = props[.string(key)],
    case .string(let s) = v.value
  else { return nil }
  return s
}

func variantInt16(_ props: [DBusValue: DBusValue], _ key: String) -> Int16? {
  guard case .variant(let v) = props[.string(key)],
    case .int16(let n) = v.value
  else { return nil }
  return n
}
