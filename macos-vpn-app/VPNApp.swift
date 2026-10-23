import SwiftUI
import Network

@main
struct VPNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var vpnManager = VPNManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "network.slash", accessibilityDescription: "VPN")
            button.action = #selector(showMenu)
        }

        setupMenu()

        vpnManager.onStatusChange = { [weak self] isConnected in
            DispatchQueue.main.async {
                self?.updateMenuIcon(connected: isConnected)
            }
        }
    }

    func setupMenu() {
        menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Connect", action: #selector(connect), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "d"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
    }

    @objc func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func connect() {
        vpnManager.connect()
    }

    @objc func disconnect() {
        vpnManager.disconnect()
    }

    @objc func openSettings() {
        SettingsWindow.show()
    }

    @objc func quit() {
        vpnManager.disconnect()
        NSApplication.shared.terminate(nil)
    }

    func updateMenuIcon(connected: Bool) {
        statusItem.button?.image = NSImage(systemSymbolName: connected ? "network" : "network.slash", accessibilityDescription: "VPN")
    }
}
