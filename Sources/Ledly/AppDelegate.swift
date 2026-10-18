import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads Settings.
        Migration.fromEgluuBundleID()

        // Development: `Ledly --read-flash <port> <out.hex>` dumps the board's firmware and quits.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--read-flash"), index + 2 < args.count {
            do {
                let data = try Flasher(path: args[index + 1]) { _ in }.readFlash()
                try Flasher.makeHex(data).write(toFile: args[index + 2], atomically: true, encoding: .utf8)
                print("Read \(data.count) bytes into \(args[index + 2])")
                exit(0)
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(1)
            }
        }

        // Development: `Ledly --flash <port> <pin>` installs the bundled firmware and quits.
        if let index = args.firstIndex(of: "--flash"), index + 2 < args.count,
           let pin = Int(args[index + 2]), let url = Firmware.url(pin: pin),
           let hex = try? String(contentsOf: url, encoding: .utf8) {
            do {
                try Flasher(path: args[index + 1]) { print("\($0)") }.flash(hex: hex)
                print("Installed \(url.lastPathComponent); backup in \(Flasher.backupFolder.path)")
                exit(0)
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(1)
            }
        }

        // Only one copy at a time: the serial port and the API port can only be opened once
        // ("Resource busy"). A second launch brings the running one forward and quits.
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0 != .current }) {
            if let url = other.bundleURL { NSWorkspace.shared.open(url) }
            NSApp.terminate(nil)
            return
        }

        setupMainMenu()
        Localizer.shared.$choice
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setupMainMenu() }
            .store(in: &cancellables)
        LEDEngine.shared.start()
        APIServer.shared.start()
        setupStatusItem()
        Updater.shared.start()

        // First launch (no strip set up yet): show the window.
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            showMain()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LEDEngine.shared.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    // MARK: - Main menu

    /// Accessory apps show no menu bar, but text fields still need an Edit menu
    /// for ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z to reach them.
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("Cerrar ventana"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: tr("Salir de Ledly"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr("Edición"))
        edit.addItem(withTitle: tr("Deshacer"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: tr("Rehacer"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("Cortar"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("Copiar"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("Pegar"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("Seleccionar todo"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: - Status bar menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        Settings.shared.$isOn
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusIcon() } }
            .store(in: &cancellables)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        statusItem.button?.image = Self.menuBarIcon(on: Settings.shared.isOn)
    }

    /// A monitor with a ring of LEDs: rainbow when the strip is on, grey when it's off.
    /// Drawn on demand so the outline follows the menu bar's light or dark appearance.
    static func menuBarIcon(on: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let screen = NSRect(x: 5, y: 5, width: 12, height: 8)
            (on ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
            let outline = NSBezierPath(roundedRect: screen, xRadius: 1.5, yRadius: 1.5)
            outline.lineWidth = 1.4
            outline.stroke()

            // LEDs around the screen, clockwise from the top left.
            var dots: [NSPoint] = []
            for x in stride(from: 6.0, through: 16.0, by: 2.5) { dots.append(NSPoint(x: x, y: 16)) }
            for y in stride(from: 11.5, through: 6.5, by: -2.5) { dots.append(NSPoint(x: 19.5, y: y)) }
            for x in stride(from: 16.0, through: 6.0, by: -2.5) { dots.append(NSPoint(x: x, y: 2)) }
            for y in stride(from: 6.5, through: 11.5, by: 2.5) { dots.append(NSPoint(x: 2.5, y: y)) }
            for (i, p) in dots.enumerated() {
                let color = on
                    ? NSColor(hue: CGFloat(i) / CGFloat(dots.count), saturation: 0.85, brightness: 1, alpha: 1)
                    : NSColor.tertiaryLabelColor
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: p.x - 1.1, y: p.y - 1.1, width: 2.2, height: 2.2)).fill()
            }
            return true
        }
        image.accessibilityDescription = on ? tr("Ledly, tira encendida") : tr("Ledly, tira apagada")
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = Settings.shared

        let power = menu.addItem(withTitle: settings.isOn ? tr("Apagar luces") : tr("Encender luces"),
                                 action: #selector(togglePower), keyEquivalent: "")
        power.target = self
        menu.addItem(.separator())

        for mode in LightMode.allCases {
            let item = menu.addItem(withTitle: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
            item.state = settings.mode == mode ? .on : .off
        }

        let effectsItem = menu.addItem(withTitle: tr("Efectos"), action: nil, keyEquivalent: "")
        let effects = NSMenu()
        for effect in EffectKind.ordered {
            let item = effects.addItem(withTitle: effect.title, action: #selector(selectEffect(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = effect.rawValue
            item.image = NSImage(systemSymbolName: effect.symbol, accessibilityDescription: nil)
            item.state = settings.mode == .effect && settings.effect == effect ? .on : .off
        }
        effectsItem.submenu = effects

        let brightnessItem = menu.addItem(withTitle: tr("Brillo"), action: nil, keyEquivalent: "")
        let brightness = NSMenu()
        for level in [10, 25, 50, 75, 100] {
            let item = brightness.addItem(withTitle: "\(level) %", action: #selector(selectBrightness(_:)), keyEquivalent: "")
            item.target = self
            item.tag = level
            item.state = Int((settings.brightness * 100).rounded()) == level ? .on : .off
        }
        brightnessItem.submenu = brightness

        menu.addItem(.separator())
        let status = menu.addItem(withTitle: deviceLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(withTitle: tr("Abrir Ledly…"), action: #selector(showMain), keyEquivalent: "o").target = self

        let login = menu.addItem(withTitle: tr("Abrir al iniciar sesión"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off

        menu.addItem(.separator())
        let updating = Updater.shared.state != .idle
        let update = menu.addItem(withTitle: updating ? tr("Actualizando…") : tr("Buscar actualizaciones…"),
                                  action: updating ? nil : #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        let coffee = menu.addItem(withTitle: tr("Invítame a un café…"), action: #selector(openBuyMeACoffee), keyEquivalent: "")
        coffee.target = self
        coffee.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        let version = menu.addItem(withTitle: "Ledly \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(withTitle: tr("Salir de Ledly"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private var deviceLine: String {
        switch LEDEngine.shared.deviceStatus {
        case .connected: return tr("Tira conectada · %d LEDs", Settings.shared.layout.count)
        case .connecting: return tr("Conectando…")
        case .disconnected: return tr("Tira desconectada")
        case .failed: return tr("Error en la tira")
        }
    }

    @objc func showMain() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Ledly"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 960, height: 620)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x14 / 255, alpha: 1)
            window.titlebarAppearsTransparent = true
            let hosting = NSHostingController(rootView: MainView())
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.center()
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePower() { Settings.shared.isOn.toggle() }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = LightMode(rawValue: raw) else { return }
        Settings.shared.mode = mode
        Settings.shared.isOn = true
    }

    @objc private func selectEffect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let effect = EffectKind(rawValue: raw) else { return }
        Settings.shared.effect = effect
        Settings.shared.mode = .effect
        Settings.shared.isOn = true
    }

    @objc private func selectBrightness(_ sender: NSMenuItem) {
        Settings.shared.brightness = Double(sender.tag) / 100
    }

    @objc private func openBuyMeACoffee() {
        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/drarek")!)
    }

    @objc private func checkForUpdates() {
        Task { await Updater.shared.check(userInitiated: true) }
    }

    @objc private func toggleLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }
}
