import AppKit
import CryptoKit

/// Self-update from GitHub releases.
///
/// Each release carries `Ledly.zip` and `Ledly.zip.sha256`. The update is
/// downloaded, checked against the hash and its Info.plist, then a detached
/// shell waits for this process to quit, swaps the bundle and relaunches it.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "drarekx/ledly"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    enum State: Equatable {
        case idle, checking, downloading, installing
    }

    @Published private(set) var state: State = .idle
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    var autoCheck: Bool {
        get { defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoCheckUpdates"); objectWillChange.send() }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        func asset(_ name: String) -> URL? { assets.first { $0.name == name }?.browser_download_url }
    }

    /// Background checks: shortly after launch, then once a day.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard autoCheck else { return }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        Task { await check(userInitiated: false) }
    }

    /// `userInitiated`: also report "up to date" and errors, and ignore skipped versions.
    func check(userInitiated: Bool) async {
        guard state == .idle else { return }
        state = .checking
        defer { if state == .checking { state = .idle } }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Ledly/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
            let release = try JSONDecoder().decode(Release.self, from: data)
            defaults.set(Date(), forKey: "lastUpdateCheck")

            guard !release.draft, !release.prerelease,
                  Self.compare(release.version, Self.currentVersion) == .orderedDescending else {
                if userInitiated { alert(tr("Ledly está actualizado"), tr("Tienes la última versión (%@).", Self.currentVersion)) }
                return
            }
            if !userInitiated, defaults.string(forKey: "skippedVersion") == release.version { return }
            state = .idle
            offer(release)
        } catch {
            if userInitiated { alert(tr("No se pudo buscar actualizaciones"), error.localizedDescription) }
        }
    }

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = tr("Ledly %@ está disponible", release.version)
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 900 { notes = String(notes.prefix(900)) + "…" }
        alert.informativeText = tr("Tienes la versión %@.", Self.currentVersion) + (notes.isEmpty ? "" : "\n\n\(notes)")
        alert.addButton(withTitle: tr("Actualizar ahora"))
        alert.addButton(withTitle: tr("Más tarde"))
        alert.addButton(withTitle: tr("Omitir esta versión"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await install(release) }
        case .alertThirdButtonReturn:
            defaults.set(release.version, forKey: "skippedVersion")
        default:
            break
        }
    }

    // MARK: - Install

    private func install(_ release: Release) async {
        let appURL = Bundle.main.bundleURL
        let parent = appURL.deletingLastPathComponent()
        guard !appURL.path.contains("/AppTranslocation/") else {
            alert(tr("No se puede actualizar desde aquí"),
                  tr("Mueve Ledly a la carpeta Aplicaciones, ábrela de nuevo y vuelve a intentarlo."))
            return
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            alert(tr("No se puede actualizar"), tr("No hay permiso para escribir en %@.\nUsa el instalador:\n\n%@", parent.path, "curl -fsSL https://raw.githubusercontent.com/\(Self.repo)/main/install.sh | bash"))
            return
        }
        guard let zipURL = release.asset("Ledly.zip"), let hashURL = release.asset("Ledly.zip.sha256") else {
            alert(tr("No se puede actualizar"), tr("La versión %@ no incluye los archivos de actualización.", release.version))
            return
        }

        state = .downloading
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Ledly-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, _) = try await URLSession.shared.download(from: zipURL)
            let zip = work.appendingPathComponent("Ledly.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)

            let (hashData, _) = try await URLSession.shared.data(from: hashURL)
            let expected = String(decoding: hashData, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard !expected.isEmpty, expected == actual else { throw UpdateError.checksum }

            state = .installing
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let newApp = work.appendingPathComponent("Ledly.app")
            guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info["CFBundleShortVersionString"] as? String == release.version else {
                throw UpdateError.invalidBundle
            }
            relaunch(replacing: appURL, with: newApp, cleanup: work)
        } catch {
            state = .idle
            try? FileManager.default.removeItem(at: work)
            alert(tr("La actualización falló"), error.localizedDescription)
        }
    }

    /// Detached helper: wait for us to exit, swap bundles (keeping a backup until the move succeeds), reopen.
    private func relaunch(replacing appURL: URL, with newApp: URL, cleanup work: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        backup="$1.old-$$"
        mv "$1" "$backup" && mv "$2" "$1" && rm -rf "$backup" || { [ -d "$backup" ] && mv "$backup" "$1"; }
        xattr -dr com.apple.quarantine "$1" 2>/dev/null
        rm -rf "$3"
        open "$1"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "wallpy-update", appURL.path, newApp.path, work.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            state = .idle
            alert(tr("La actualización falló"), error.localizedDescription)
        }
    }

    private func run(_ path: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.unzip)
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: - Helpers

    /// Numeric comparison of dotted versions ("1.10.0" > "1.9.2").
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0, r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

enum UpdateError: LocalizedError {
    case server, checksum, unzip, invalidBundle

    var errorDescription: String? {
        switch self {
        case .server: return tr("GitHub no respondió correctamente. Inténtalo más tarde.")
        case .checksum: return tr("El archivo descargado no coincide con su huella SHA-256. No se ha instalado nada.")
        case .unzip: return tr("No se pudo descomprimir la actualización.")
        case .invalidBundle: return tr("La descarga no contiene una versión válida de Ledly.")
        }
    }
}
