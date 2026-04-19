import AppKit
import SwiftUI
import Combine
import ServiceManagement

// MARK: - Login Item

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
    static func set(_ enabled: Bool) throws {
        let svc = SMAppService.mainApp
        if enabled {
            if svc.status != .enabled { try svc.register() }
        } else {
            if svc.status == .enabled { try svc.unregister() }
        }
    }
}

// MARK: - Brand

extension Color {
    static let claudeOrange = Color(red: 204/255, green: 120/255, blue: 92/255)  // #CC785C
}

// MARK: - Configuration

struct AppConfig: Codable {
    var refreshInterval: TimeInterval
    var showDesktopWidget: Bool
    var widgetX: Double
    var widgetY: Double
    var warningPercent: Int  // Show warning at this usage %

    static let `default` = AppConfig(
        refreshInterval: 120,
        showDesktopWidget: true,
        widgetX: 40,
        widgetY: 40,
        warningPercent: 80
    )

    static var configDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude-usage-widget"
    }
    static var configPath: String { "\(configDir)/config.json" }

    static func load() -> AppConfig {
        if let data = FileManager.default.contents(atPath: configPath),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return decoded
        }
        return .default
    }

    func save() {
        try? FileManager.default.createDirectory(atPath: AppConfig.configDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(self) {
            FileManager.default.createFile(atPath: AppConfig.configPath, contents: data)
        }
    }
}

// MARK: - Usage Data Model

struct UsageBucket {
    var utilization: Double  // percentage 0-100
    var resetsAt: Date?
    var resetsAtStr: String = ""
}

struct ExtraUsage {
    var isEnabled: Bool
    var monthlyLimit: Int
    var usedCredits: Double
    var utilization: Double?
}

struct PrepaidBalance {
    var amount: Int       // in cents
    var currency: String  // "EUR", "USD"

    var currencySymbol: String {
        switch currency.uppercased() {
        case "EUR": return "€"
        case "USD": return "$"
        case "GBP": return "£"
        default: return currency
        }
    }
    var formatted: String {
        let value = Double(amount) / 100.0
        return String(format: "%@%.2f", currencySymbol, value)
    }
}

class UsageStore: ObservableObject {
    @Published var session = UsageBucket(utilization: 0)       // five_hour
    @Published var weeklyAll = UsageBucket(utilization: 0)     // seven_day
    @Published var weeklySonnet = UsageBucket(utilization: 0)  // seven_day_sonnet
    @Published var weeklyOpus: UsageBucket?                    // seven_day_opus
    @Published var weeklyDesign: UsageBucket?                  // seven_day_omelette (Claude Design)
    @Published var extra = ExtraUsage(isEnabled: false, monthlyLimit: 0, usedCredits: 0)
    @Published var prepaid: PrepaidBalance?
    @Published var lastUpdated: Date?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasData = false
    var config = AppConfig.load()

    var menuBarDisplay: String {
        guard hasData else { return "◆ —" }
        let sessionPct = Int(session.utilization)
        return "◆ \(sessionPct)%"
    }

    var sessionColor: Color {
        colorForUsage(session.utilization)
    }

    func colorForUsage(_ pct: Double) -> Color {
        if pct < 50 { return .green }
        if pct < Double(config.warningPercent) { return .yellow }
        return .red
    }

    func isOverWarning(_ pct: Double) -> Bool {
        pct >= Double(config.warningPercent)
    }

    func timeUntilReset(_ bucket: UsageBucket) -> String {
        guard let d = bucket.resetsAt else { return "—" }
        let interval = d.timeIntervalSinceNow
        if interval <= 0 { return "jetzt" }
        let h = Int(interval) / 3600
        let m = (Int(interval) % 3600) / 60
        if h > 24 {
            let days = h / 24
            let remH = h % 24
            return "\(days)T \(remH)h"
        }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m) min"
    }

    func resetLabel(_ bucket: UsageBucket) -> String {
        guard let d = bucket.resetsAt else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        // Include date when reset is > 24h away so "Sa" is unambiguous
        let hoursAway = d.timeIntervalSinceNow / 3600
        f.dateFormat = hoursAway > 24 ? "EEE dd.MM HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }

    func update(from json: [String: Any]) {
        DispatchQueue.main.async {
            self.hasData = true
            self.isLoading = false
            self.errorMessage = nil
            self.lastUpdated = Date()

            if let fh = json["five_hour"] as? [String: Any] {
                self.session = self.parseBucket(fh)
            }
            if let sd = json["seven_day"] as? [String: Any] {
                self.weeklyAll = self.parseBucket(sd)
            }
            if let ss = json["seven_day_sonnet"] as? [String: Any] {
                self.weeklySonnet = self.parseBucket(ss)
            }
            if let so = json["seven_day_opus"] as? [String: Any] {
                self.weeklyOpus = self.parseBucket(so)
            } else {
                self.weeklyOpus = nil
            }
            if let sde = json["seven_day_omelette"] as? [String: Any] {
                self.weeklyDesign = self.parseBucket(sde)
            } else {
                self.weeklyDesign = nil
            }
            if let ex = json["extra_usage"] as? [String: Any] {
                self.extra = ExtraUsage(
                    isEnabled: ex["is_enabled"] as? Bool ?? false,
                    monthlyLimit: ex["monthly_limit"] as? Int ?? 0,
                    usedCredits: ex["used_credits"] as? Double ?? 0,
                    utilization: ex["utilization"] as? Double
                )
            }
            if let pp = json["prepaid"] as? [String: Any] {
                self.prepaid = PrepaidBalance(
                    amount: pp["amount"] as? Int ?? 0,
                    currency: pp["currency"] as? String ?? "USD"
                )
            } else {
                self.prepaid = nil
            }
        }
    }

    private func parseBucket(_ dict: [String: Any]) -> UsageBucket {
        var b = UsageBucket(utilization: dict["utilization"] as? Double ?? 0)
        if let rs = dict["resets_at"] as? String {
            b.resetsAtStr = rs
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            b.resetsAt = f.date(from: rs)
            if b.resetsAt == nil {
                f.formatOptions = [.withInternetDateTime]
                b.resetsAt = f.date(from: rs)
            }
        }
        return b
    }
}

// MARK: - Python Fetcher

class UsageFetcher {
    let scriptPath: String

    init() {
        // Find the Python script next to the app bundle or in known location
        let bundle = Bundle.main.bundlePath
        let appDir = (bundle as NSString).deletingLastPathComponent
        let candidates = [
            "\(appDir)/fetch_usage.py",
            "\((bundle as NSString).deletingLastPathComponent)/fetch_usage.py",
            "\(AppConfig.configDir)/fetch_usage.py",
            // Dev path
            (ProcessInfo.processInfo.arguments.first.map { ($0 as NSString).deletingLastPathComponent + "/fetch_usage.py" } ?? ""),
        ]
        scriptPath = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }

    func fetch(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptPath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            completion(.failure(error))
            return
        }

        DispatchQueue.global().async {
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
                completion(.failure(NSError(domain: "fetch", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Keine Ausgabe vom Script"])))
                return
            }

            guard let jsonData = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                completion(.failure(NSError(domain: "fetch", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Ungueltige JSON Antwort"])))
                return
            }

            if let err = json["error"] as? String {
                completion(.failure(NSError(domain: "fetch", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: err])))
            } else {
                completion(.success(json))
            }
        }
    }
}

// MARK: - Helpers

func fmtPct(_ v: Double) -> String { "\(Int(v))%" }

// MARK: - SwiftUI Views

let widgetWidth: CGFloat = 340

struct UsageRow: View {
    let title: String
    let subtitle: String
    let pct: Double
    let color: Color
    let resetInfo: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Text(fmtPct(pct))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.6), color],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geo.size.width * CGFloat(min(pct / 100.0, 1.0))))
                }
            }
            .frame(height: 10)

            if !resetInfo.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9))
                    Text(resetInfo)
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary.opacity(0.6))
            }
        }
    }
}

struct SectionLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.5)
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
        .foregroundColor(.secondary.opacity(0.55))
    }
}

struct WidgetContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.claudeOrange)
                Text("Claude Usage")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if store.isLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                }
            }

            if let error = store.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
            } else if !store.hasData {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Lade Usage-Daten...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            } else {
                // Session (5-hour)
                SectionLabel(icon: "bolt.fill", title: "Aktuelle Session")
                UsageRow(
                    title: "Verbrauch",
                    subtitle: "",
                    pct: store.session.utilization,
                    color: store.colorForUsage(store.session.utilization),
                    resetInfo: "Reset in \(store.timeUntilReset(store.session))"
                )

                // Weekly
                SectionLabel(icon: "calendar", title: "Woche")
                UsageRow(
                    title: "Alle Modelle",
                    subtitle: "Reset \(store.resetLabel(store.weeklyAll))",
                    pct: store.weeklyAll.utilization,
                    color: store.colorForUsage(store.weeklyAll.utilization),
                    resetInfo: "Reset in \(store.timeUntilReset(store.weeklyAll))"
                )

                UsageRow(
                    title: "Sonnet",
                    subtitle: "",
                    pct: store.weeklySonnet.utilization,
                    color: store.colorForUsage(store.weeklySonnet.utilization),
                    resetInfo: ""
                )

                if let opus = store.weeklyOpus {
                    UsageRow(
                        title: "Opus",
                        subtitle: "",
                        pct: opus.utilization,
                        color: store.colorForUsage(opus.utilization),
                        resetInfo: ""
                    )
                }

                if let design = store.weeklyDesign {
                    UsageRow(
                        title: "Claude Design",
                        subtitle: store.resetLabel(design).isEmpty ? "" : "Reset \(store.resetLabel(design))",
                        pct: design.utilization,
                        color: store.colorForUsage(design.utilization),
                        resetInfo: store.timeUntilReset(design) == "—" ? "" : "Reset in \(store.timeUntilReset(design))"
                    )
                }

                // Extra Usage
                if store.extra.isEnabled {
                    SectionLabel(icon: "creditcard", title: "Extra Usage")

                    // Current Balance (top, prominent)
                    if let pp = store.prepaid {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Current Balance")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                Text(pp.formatted)
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .foregroundColor(pp.amount > 0 ? .green : .primary.opacity(0.4))
                            }
                            Spacer()
                            Image(systemName: "wallet.pass.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.green.opacity(0.3))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color.green.opacity(0.06))
                        .cornerRadius(8)
                    }

                    // Spent / Limit
                    let curSym = store.prepaid?.currencySymbol ?? "$"
                    HStack(spacing: 0) {
                        VStack(spacing: 2) {
                            Text(String(format: "%@%.2f", curSym, store.extra.usedCredits / 100.0))
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(store.extra.usedCredits > 0 ? .orange : .primary.opacity(0.4))
                            Text("Verbraucht")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)

                        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: 30)

                        VStack(spacing: 2) {
                            Text(String(format: "%@%.0f", curSym, Double(store.extra.monthlyLimit) / 100.0))
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(.primary.opacity(0.5))
                            Text("Monatslimit")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                }

                // Footer
                HStack {
                    Spacer()
                    if let updated = store.lastUpdated {
                        Text("Aktualisiert: ")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.4))
                        +
                        Text(updated, style: .relative)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                }
            }
        }
        .padding(16)
        .frame(width: widgetWidth)
    }
}

// MARK: - Desktop Widget

struct DesktopWidgetView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        WidgetContentView(store: store)
            .background(
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blendingMode; v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let onRefresh: () -> Void
    let onToggleWidget: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void
    @State private var widgetVisible: Bool

    init(store: UsageStore, widgetVisible: Bool,
         onRefresh: @escaping () -> Void,
         onToggleWidget: @escaping () -> Void,
         onSettings: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.store = store
        self._widgetVisible = State(initialValue: widgetVisible)
        self.onRefresh = onRefresh
        self.onToggleWidget = onToggleWidget
        self.onSettings = onSettings
        self.onQuit = onQuit
    }

    var body: some View {
        VStack(spacing: 0) {
            WidgetContentView(store: store)
            Divider().padding(.horizontal, 14)
            VStack(spacing: 2) {
                popButton(icon: "arrow.clockwise", label: "Aktualisieren", action: onRefresh)
                popButton(icon: widgetVisible ? "eye.slash" : "eye",
                    label: widgetVisible ? "Desktop-Widget ausblenden" : "Desktop-Widget einblenden") {
                    widgetVisible.toggle(); onToggleWidget()
                }
                popButton(icon: "gearshape", label: "Einstellungen...", action: onSettings)
                Divider().padding(.horizontal, 14)
                popButton(icon: "xmark.circle", label: "Beenden", action: onQuit)
            }
            .padding(.vertical, 6)
        }
        .frame(width: widgetWidth)
    }

    func popButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 18)
                Text(label).font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - Settings

func installEditMenu() {
    let mainMenu = NSMenu()
    let appItem = NSMenuItem(); let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu; mainMenu.addItem(appItem)
    let editItem = NSMenuItem(); let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu; mainMenu.addItem(editItem)
    NSApp.mainMenu = mainMenu
}

class SettingsWindowController {
    var window: NSWindow?
    var config: AppConfig
    let onSave: (AppConfig) -> Void

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self.config = config; self.onSave = onSave
    }

    func show() {
        installEditMenu()
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let view = SettingsView(config: config) { [weak self] c in
            self?.onSave(c); self?.window?.close(); self?.window = nil
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Claude Usage - Einstellungen"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 460, height: 360))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }
}

struct SettingsView: View {
    @State var refreshMinutes: Double
    @State var warningPercent: Double
    @State var autoStart: Bool
    @State var autoStartError: String?
    let onSave: (AppConfig) -> Void

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        _refreshMinutes = State(initialValue: config.refreshInterval / 60.0)
        _warningPercent = State(initialValue: Double(config.warningPercent))
        _autoStart = State(initialValue: LoginItem.isEnabled)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Einstellungen")
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Aktualisierungs-Intervall")
                    .font(.system(size: 14, weight: .medium))
                HStack(spacing: 12) {
                    Slider(value: $refreshMinutes, in: 1...15, step: 1)
                    Text("\(Int(refreshMinutes)) Min")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .frame(width: 60, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Warnung ab")
                    .font(.system(size: 14, weight: .medium))
                HStack(spacing: 12) {
                    Slider(value: $warningPercent, in: 50...95, step: 5)
                    Text("\(Int(warningPercent))%")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(warningPercent > 80 ? .red : .orange)
                        .frame(width: 60, alignment: .trailing)
                }
                Text("Balken werden rot wenn der Verbrauch diesen Wert ueberschreitet")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $autoStart) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Beim Login automatisch starten")
                            .font(.system(size: 14, weight: .medium))
                        Text("Claude Usage oeffnet sich bei jedem Systemstart")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: autoStart) { _, newValue in
                    do {
                        try LoginItem.set(newValue)
                        autoStartError = nil
                    } catch {
                        autoStart = LoginItem.isEnabled
                        autoStartError = error.localizedDescription
                    }
                }
                if let err = autoStartError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }

            Spacer()

            HStack {
                Text("Daten kommen automatisch aus Claude Desktop")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Speichern") {
                    var config = AppConfig.load()
                    config.refreshInterval = refreshMinutes * 60
                    config.warningPercent = Int(warningPercent)
                    config.save()
                    onSave(config)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

// MARK: - Desktop Widget Window

class DesktopWidgetController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    let store: UsageStore
    var config: AppConfig

    init(store: UsageStore, config: AppConfig) {
        self.store = store; self.config = config
    }

    func show() {
        guard window == nil else { window?.orderFront(nil as AnyObject?); return }
        let hosting = NSHostingView(rootView: DesktopWidgetView(store: store))
        let rect = NSRect(x: config.widgetX, y: config.widgetY, width: Double(widgetWidth), height: 600)
        let w = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = hosting
        w.isOpaque = false
        w.backgroundColor = NSColor.clear
        // Normal level so the window is clickable/draggable. Prior desktopIconWindow
        // level rendered it behind the Finder desktop and ate all mouse events.
        w.level = .normal
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isMovableByWindowBackground = true
        w.hasShadow = false
        w.delegate = self
        w.orderFront(nil as AnyObject?)
        self.window = w
    }

    func hide() { window?.orderOut(nil as AnyObject?); window = nil }
    func toggle() { if window != nil { hide() } else { show() } }
    var isVisible: Bool { window != nil }

    // Persist new position whenever the user drags the widget.
    func windowDidMove(_ notification: Notification) {
        guard let w = window else { return }
        config.widgetX = Double(w.frame.origin.x)
        config.widgetY = Double(w.frame.origin.y)
        config.save()
    }
}

// MARK: - Menu Bar Controller

class MenuBarController: NSObject, NSPopoverDelegate {
    let statusItem: NSStatusItem
    let popover = NSPopover()
    let store: UsageStore
    var desktopWidget: DesktopWidgetController
    var settingsController: SettingsWindowController?
    var config: AppConfig
    let fetcher = UsageFetcher()
    var refreshTimer: Timer?
    var cancellables = Set<AnyCancellable>()
    var outsideClickMonitor: Any?

    init(store: UsageStore, config: AppConfig) {
        self.store = store; self.config = config
        self.desktopWidget = DesktopWidgetController(store: store, config: config)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let btn = statusItem.button {
            btn.title = "◆ —"
            btn.action = #selector(togglePopover)
            btn.target = self
        }
        observeStore()
        if config.showDesktopWidget { desktopWidget.show() }
        startTimer()
        refresh()
    }

    func observeStore() {
        store.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.statusItem.button?.title = self.store.menuBarDisplay
            }
            .store(in: &cancellables)
    }

    func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: config.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        store.isLoading = true
        fetcher.fetch { [weak self] result in
            switch result {
            case .success(let json): self?.store.update(from: json)
            case .failure(let error):
                DispatchQueue.main.async {
                    self?.store.isLoading = false
                    self?.store.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func showSettings() {
        popover.performClose(nil)
        if settingsController == nil {
            settingsController = SettingsWindowController(config: config) { [weak self] c in
                self?.config = c; self?.store.config = c; self?.startTimer()
            }
        }
        settingsController?.config = config
        settingsController?.show()
    }

    func toggleWidget() {
        desktopWidget.toggle()
        config.showDesktopWidget = desktopWidget.isVisible
        config.save()
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let btn = statusItem.button else { return }
        let hosting = NSHostingController(rootView: PopoverView(
            store: store, widgetVisible: desktopWidget.isVisible,
            onRefresh: { [weak self] in self?.refresh() },
            onToggleWidget: { [weak self] in self?.toggleWidget() },
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        ))
        // Make NSPopover size to SwiftUI intrinsic, else top clips
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        startOutsideClickMonitor()
    }

    func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    func stopOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = AppConfig.load()
        let store = UsageStore()
        store.config = config
        controller = MenuBarController(store: store, config: config)
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
