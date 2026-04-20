#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#elseif canImport(Musl)
  import Musl
#endif
import DBUS
import Logging
import NIOCore

// avahi.dbus.swift is auto-generated from avahi.dbus.xml by DBusCodegenPlugin.
// It provides: OrgFreedesktopAvahiServerProxy, OrgFreedesktopAvahiServiceBrowserProxy

@main
struct AvahiBrowse {
  static func main() async throws {
    var logger = Logger(label: "avahi.browse")
    logger.logLevel = .info

    let systemSocket = try SocketAddress(unixDomainSocketPath: "/var/run/dbus/system_bus_socket")
    let uid = String(getuid())

    try await DBusClient.withConnection(
      to: systemSocket,
      auth: .external(userID: uid),
      logger: logger
    ) { connection in
      // Proxy for the main Avahi server object.
      let server = OrgFreedesktopAvahiServerProxy(
        connection: connection,
        destination: "org.freedesktop.Avahi",
        path: "/"
      )

      let version = try await server.getVersionString()
      print("Avahi \(version) — browsing for _http._tcp…")

      // Ask Avahi to create a browser for HTTP services on any network interface
      // and any protocol (IPv4 + IPv6).
      //   -1 = AVAHI_IF_UNSPEC   (any interface)
      //   -1 = AVAHI_PROTO_UNSPEC (any protocol)
      let browserPath = try await server.serviceBrowserNew(
        interface: -1,
        protocol: -1,
        type: "_http._tcp",
        domain: "",
        flags: 0
      )

      // Avahi returns an object path for the new browser.
      // Create a proxy pointing at it.
      let browser = OrgFreedesktopAvahiServiceBrowserProxy(
        connection: connection,
        destination: "org.freedesktop.Avahi",
        path: browserPath
      )

      // Subscribe to the signals we care about.
      let newServices = try await browser.itemNew()
      let removedServices = try await browser.itemRemove()
      let done = try await browser.allForNow()
      let failures = try await browser.failure()

      // Drive signal streams concurrently until AllForNow fires.
      // cancelAll() must come from the outer closure, not inside addTask.
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await svc in newServices {
            print("  [+] \(svc.name).\(svc.`type`).\(svc.domain)")
          }
        }
        group.addTask {
          for await svc in removedServices {
            print("  [-] \(svc.name).\(svc.`type`).\(svc.domain)")
          }
        }
        group.addTask {
          for await error in failures {
            print("  [!] Browser error: \(error)")
          }
        }
        // Suspend the parent until AllForNow fires, then cancel the child tasks.
        for await _ in done { break }
        print("Initial browse complete.")
        group.cancelAll()
      }
    }
  }
}
