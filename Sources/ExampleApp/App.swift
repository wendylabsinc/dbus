import DBUS
import Logging
import NIOCore

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

@available(macOS 10.15, *)
@main
struct App {
  static func main() async throws {
    let logger = Logger(label: "dbus.example.bluez")
    let systemSocket = try SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket")
    let uid = String(getuid())

    try await DBusClient.withConnection(
      to: systemSocket,
      auth: .external(userID: uid),
      logger: logger
    ) { connection in
      let server = DBusObjectServer(connection: connection, logger: logger)

      // Advertisement ---------------------------------------------------------
      let advPath = "/com/wendylabs/example/adv0"
      var advInterface = DBusObjectServer.Interface(name: "org.bluez.LEAdvertisement1")
      advInterface.methods = [
        .init(name: "Release") { ctx in
          logger.info("Advertisement released", metadata: ["sender": "\(ctx.sender ?? "")"])
          return []
        }
      ]
      advInterface.properties = [
        .init(name: "Type", value: .string("peripheral")),
        .init(name: "LocalName", value: .string("WendyDemo")),
        .init(
          name: "ServiceUUIDs",
          value: .array([.string("1234")])
        ),
      ]
      await server.export(.init(path: advPath, interfaces: [advInterface]))

      // GATT ------------------------------------------------------------------
      let gattRootPath = "/com/wendylabs/example/gatt"
      let servicePath = "\(gattRootPath)/service0"
      let characteristicPath = "\(servicePath)/char0"
      let descriptorPath = "\(characteristicPath)/desc0"

      let serviceUUID = "12345678-1234-5678-1234-56789abcdef0"
      let characteristicUUID = "12345678-1234-5678-1234-56789abcdef1"
      let descriptorUUID = "12345678-1234-5678-1234-56789abcdef2"

      let valueStore = ValueStore(initial: [0x48, 0x69])  // "Hi"

      let appInterface = DBusObjectServer.Interface(name: "org.bluez.GattApplication1")
      await server.export(
        .init(path: gattRootPath, interfaces: [appInterface], exposesObjectManager: true))

      let serviceInterface = DBusObjectServer.Interface(
        name: "org.bluez.GattService1",
        methods: [],
        properties: [
          .init(name: "UUID", value: .string(serviceUUID)),
          .init(name: "Primary", value: .boolean(true)),
          .init(name: "Includes", signature: "ao", get: { _ in .array([]) }),
        ]
      )
      await server.export(.init(path: servicePath, interfaces: [serviceInterface]))

      var characteristicInterface = DBusObjectServer.Interface(
        name: "org.bluez.GattCharacteristic1",
        methods: [],
        properties: [
          .init(name: "UUID", value: .string(characteristicUUID)),
          .init(name: "Service", value: .objectPath(servicePath)),
          .init(name: "Flags", value: .array([.string("read"), .string("write")])),
          .init(name: "Descriptors", value: .array([.objectPath(descriptorPath)])),
        ]
      )

      characteristicInterface.methods.append(
        .init(
          name: "ReadValue",
          inputArgs: [.init(name: "options", type: "a{sv}")],
          outputArgs: [.init(name: "value", type: "ay")]
        ) { _ in
          let bytes = await valueStore.read()
          return [.array(bytes.map { DBusValue.byte($0) })]
        }
      )

      characteristicInterface.methods.append(
        .init(
          name: "WriteValue",
          inputArgs: [.init(name: "value", type: "ay"), .init(name: "options", type: "a{sv}")],
          outputArgs: []
        ) { ctx in
          guard
            let byteArray = ctx.arguments.first?.array?.compactMap(\.uint8)
          else {
            return []
          }
          await valueStore.write(bytes: byteArray)
          logger.info("Characteristic write", metadata: ["bytes": "\(byteArray)"])
          return []
        }
      )

      await server.export(.init(path: characteristicPath, interfaces: [characteristicInterface]))

      let descriptorInterface = DBusObjectServer.Interface(
        name: "org.bluez.GattDescriptor1",
        methods: [
          .init(
            name: "ReadValue",
            inputArgs: [.init(name: "options", type: "a{sv}")],
            outputArgs: [.init(name: "value", type: "ay")]
          ) { _ in
            let bytes = await valueStore.read()
            return [.array(bytes.map { DBusValue.byte($0) })]
          },
        ],
        properties: [
          .init(name: "UUID", value: .string(descriptorUUID)),
          .init(name: "Characteristic", value: .objectPath(characteristicPath)),
          .init(name: "Flags", value: .array([.string("read")])),
        ]
      )
      await server.export(.init(path: descriptorPath, interfaces: [descriptorInterface]))

      // Register with BlueZ managers
      let advRegister = DBusRequest.createMethodCall(
        destination: "org.bluez",
        path: "/org/bluez/hci0",
        interface: "org.bluez.LEAdvertisingManager1",
        method: "RegisterAdvertisement",
        body: [
          .objectPath(advPath),
          .dictionary([:]),  // options a{sv}
        ]
      )
      _ = try await connection.send(advRegister)
      logger.info("Registered advertisement at \(advPath)")

      let gattRegister = DBusRequest.createMethodCall(
        destination: "org.bluez",
        path: "/org/bluez/hci0",
        interface: "org.bluez.GattManager1",
        method: "RegisterApplication",
        body: [
          .objectPath(gattRootPath),
          .dictionary([:]),  // options a{sv}
        ]
      )
      _ = try await connection.send(gattRegister)
      logger.info("Registered GATT application at \(gattRootPath)")

      logger.info("Server running. Inspect with `bluetoothctl` or `busctl introspect org.bluez \(advPath)`")
      // Keep the connection alive
      try await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)  // 1 hour
    }
  }
}

actor ValueStore {
  private var bytes: [UInt8]

  init(initial: [UInt8]) {
    self.bytes = initial
  }

  func read() -> [UInt8] {
    bytes
  }

  func write(bytes: [UInt8]) {
    self.bytes = bytes
  }
}
