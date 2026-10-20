// Preferences and the Settings window.

import AppKit
import ServiceManagement
import SwiftUI

let repoURL = URL(string: "https://github.com/pgsohail/dropovr")!

enum Prefs {
    private static let defaults = UserDefaults.standard

    static var shakeEnabled: Bool { defaults.object(forKey: "shakeEnabled") as? Bool ?? true }
    /// 0 = low (needs a big shake), 1 = medium, 2 = high (opens easily).
    static var shakeSensitivity: Int { defaults.object(forKey: "shakeSensitivity") as? Int ?? 1 }
    static var hotKeyEnabled: Bool { defaults.object(forKey: "hotKeyEnabled") as? Bool ?? true }
    /// 0 = remove items only when they're moved, 1 = remove after any drop.
    static var removeAfterDrag: Int { defaults.object(forKey: "removeAfterDrag") as? Int ?? 0 }
    static var darkness: Double { defaults.object(forKey: "darkness") as? Double ?? 0.86 }
    static var phoneAlwaysOn: Bool { defaults.bool(forKey: "phoneAlwaysOn") }
    static var clipboardHotKeyEnabled: Bool { defaults.object(forKey: "clipboardHotKeyEnabled") as? Bool ?? true }
    static var notchEnabled: Bool { defaults.object(forKey: "notchEnabled") as? Bool ?? true }
    static var screenshotsEnabled: Bool { defaults.object(forKey: "screenshotsEnabled") as? Bool ?? true }

    static var phoneUseHostname: Bool { defaults.object(forKey: "phoneUseHostname") as? Bool ?? true }

    /// The secret part of the always-on phone link. Stays the same until reset.
    static var phoneToken: String {
        if let token = defaults.string(forKey: "phoneToken") { return token }
        return resetPhoneToken()
    }

    @discardableResult
    static func resetPhoneToken() -> String {
        let token = (0..<4).map { _ in String(format: "%04x", UInt16.random(in: .min ... .max)) }.joined()
        defaults.set(token, forKey: "phoneToken")
        return token
    }
}

extension Notification.Name {
    static let phoneLinkChanged = Notification.Name("DropovrPhoneLinkChanged")
}

// MARK: - Window

enum SettingsWindow {
    private static var window: NSWindow?
    private static let model = SettingsModel()

    static func show(tab: SettingsView.Tab = .general) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: host)
            created.title = "Dropovr Settings"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        model.tab = tab
        model.refreshLogin()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Window state that would normally be @State (kept in an object so it builds with the
/// command-line tools alone).
final class SettingsModel: ObservableObject {
    @Published var tab: SettingsView.Tab = .general
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?

    func refreshLogin() { openAtLogin = SMAppService.mainApp.status == .enabled }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        refreshLogin()
    }
}

final class PhoneLinkModel: ObservableObject {
    @Published var link: URL? = PhoneServer.shared.link
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .phoneLinkChanged, object: nil, queue: .main) { [weak self] _ in
            self?.link = PhoneServer.shared.link
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }
}

// MARK: - Content

struct SettingsView: View {
    enum Tab: Hashable { case general, shelf, phone, about }

    @ObservedObject var model: SettingsModel
    @AppStorage("shakeEnabled") private var shakeEnabled = true
    @AppStorage("shakeSensitivity") private var shakeSensitivity = 1
    @AppStorage("hotKeyEnabled") private var hotKeyEnabled = true
    @AppStorage("clipboardHotKeyEnabled") private var clipboardHotKeyEnabled = true
    @AppStorage("notchEnabled") private var notchEnabled = true
    @AppStorage("screenshotsEnabled") private var screenshotsEnabled = true

    @AppStorage("removeAfterDrag") private var removeAfterDrag = 0
    @AppStorage("darkness") private var darkness = 0.86
    @AppStorage("phoneAlwaysOn") private var phoneAlwaysOn = false
    @AppStorage("phoneUseHostname") private var phoneUseHostname = true
    @StateObject private var phone = PhoneLinkModel()

    var body: some View {
        TabView(selection: $model.tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            shelf.tabItem { Label("Shelf", systemImage: "tray") }.tag(Tab.shelf)
            phoneTab.tabItem { Label("Phone", systemImage: "iphone") }.tag(Tab.phone)
            about.tabItem { Label("About", systemImage: "info.circle") }.tag(Tab.about)
        }
        .padding(.top, 8)
        .frame(width: 480, height: 540)
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Open Dropovr at login", isOn: Binding(get: { model.openAtLogin }, set: model.setOpenAtLogin))
                if let loginError = model.loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Opening a shelf") {
                Toggle("Shake the mouse while dragging", isOn: $shakeEnabled)
                Picker("Shake sensitivity", selection: $shakeSensitivity) {
                    Text("Low").tag(0)
                    Text("Medium").tag(1)
                    Text("High").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(!shakeEnabled)
                Toggle("Drag to the notch (top middle of the screen)", isOn: $notchEnabled)
                Toggle("Keyboard shortcut ⌃⌥S", isOn: $hotKeyEnabled)
            }
            Section("Automatic") {
                Toggle("Put new screenshots on a shelf", isOn: $screenshotsEnabled)
                Toggle("⌃⌥V puts what you copied on a shelf", isOn: $clipboardHotKeyEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private var shelf: some View {
        Form {
            Section("Dragging out") {
                Picker("After you drop an item somewhere", selection: $removeAfterDrag) {
                    Text("Remove it only if it was moved").tag(0)
                    Text("Always remove it").tag(1)
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                LabeledContent("Copy Share Link") { Text("Links expire on their own").foregroundStyle(.secondary) }
            } header: {
                Text("Share links")
            } footer: {
                Text("“Copy Share Link” uploads the file to a free temporary host: Litterbox (ad-free, 1 day, up to 1 GB), or tmpfiles.org (1 hour, up to 100 MB; its download page shows its own ads) if Litterbox is busy. Anyone with the link can download it until it expires. Nothing is uploaded unless you choose it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Look") {
                LabeledContent("Glass darkness") {
                    Slider(value: $darkness, in: 0.55...0.97) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "sun.max")
                    } maximumValueLabel: {
                        Image(systemName: "moon.fill")
                    }
                }
            }
            Section {
                LabeledContent("Saved snippets") {
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([stashDir]) }
                        Button("Move to Bin") { clearSnippets() }
                    }
                }
            } footer: {
                Text("Text, images and links you drop are saved as small files so you can drag them out again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var phoneTab: some View {
        Form {
            Section {
                Toggle("Always-on phone link", isOn: $phoneAlwaysOn)
            } footer: {
                Text("Keeps one permanent link, so your phone can open your shelf any time your Mac is awake and on the same Wi‑Fi. Add it to your phone's Home Screen and it works like an app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if phoneAlwaysOn {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        if let link = phone.link, let qr = PhoneServer.qrCode(link.absoluteString, side: 120) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 120, height: 120)
                                .padding(8)
                                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        } else {
                            ProgressView().frame(width: 136, height: 136)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scan with your phone").font(.headline)
                            Text("iPhone: tap Share → Add to Home Screen.\nAndroid: tap ⋮ → Add to Home screen.")
                                .font(.callout).foregroundStyle(.secondary)
                            Text(phone.link?.absoluteString ?? "Starting…")
                                .font(.caption.monospaced()).textSelection(.enabled)
                            HStack {
                                Button("Copy Link") {
                                    guard let link = phone.link else { return }
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                                }
                                Button("New Link") { Prefs.resetPhoneToken() }
                                    .help("Makes a new link. Phones using the old one stop working.")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Toggle("Use this Mac's name instead of its IP address", isOn: $phoneUseHostname)
                } footer: {
                    Text("The Mac's name keeps working when your Wi‑Fi gives the Mac a new address. Best for iPhone; turn it off if an Android phone can't connect.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Dropovr").font(.title.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .foregroundStyle(.secondary)
            Text("A free, open-source floating shelf for your Mac.").foregroundStyle(.secondary)
            Link("View on GitHub", destination: repoURL)
            Spacer().frame(height: 6)
            Text("⌃⌥S new shelf · ⌃⌥V clipboard to shelf · Space Quick Look · ⌘P pin · Esc close")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clearSnippets() {
        let items = (try? disk.contentsOfDirectory(at: stashDir, includingPropertiesForKeys: nil)) ?? []
        NSWorkspace.shared.recycle(items, completionHandler: nil)
    }
}
