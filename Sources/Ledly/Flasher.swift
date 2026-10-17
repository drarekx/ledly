import Foundation

/// Firmware images bundled with the app, one per data pin.
enum Firmware {
    static let pins = Array(2...13)
    static let baud = 1_000_000
    /// Rates of older Ledly firmware, still accepted when connecting.
    static let legacyBauds = [500_000]
    static let version = 2

    static func url(pin: Int) -> URL? {
        let name = "ledly-pin\(pin)"
        if let url = Bundle.main.url(forResource: name, withExtension: "hex", subdirectory: "Firmware") {
            return url
        }
        // `swift run` from the repository: use firmware/hex next to the sources.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("firmware/hex/\(name).hex")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }
}

enum FlashError: LocalizedError {
    case badHex(Int)
    case tooBig(Int)
    case noBootloader
    case wrongChip(String)
    case protocolError(String)
    case verify(Int)

    var errorDescription: String? {
        switch self {
        case .badHex(let line): return tr("El archivo de firmware está dañado (línea %d).", line)
        case .tooBig(let size): return tr("El firmware ocupa %d bytes y no cabe en el ATmega328P.", size)
        case .noBootloader: return tr("El bootloader no responde. Comprueba que es un Arduino Nano y prueba a pulsar reset justo al instalar.")
        case .wrongChip(let sig): return tr("El chip no es un ATmega328P (firma %@).", sig)
        case .protocolError(let step): return tr("Fallo de comunicación con el bootloader (%@).", step)
        case .verify(let address): return tr("La verificación falló en la dirección 0x%04X.", address)
        }
    }
}

/// Uploads an Intel HEX image to an Arduino Nano through its serial bootloader
/// (STK500 v1: Optiboot at 115200 baud, or the old ATmegaBOOT at 57600).
final class Flasher {
    enum Step: Equatable {
        case connecting, backingUp(Double), writing(Double), verifying(Double), done
    }

    private static let pageSize = 128
    private static let flashLimit = 30 * 1024   // 32 KB minus the 2 KB bootloader area

    // STK500 v1 constants.
    private static let syncCRC: UInt8 = 0x20
    private static let inSync: UInt8 = 0x14
    private static let ok: UInt8 = 0x10

    private let port: SerialPort
    private let progress: (Step) -> Void

    init(path: String, progress: @escaping (Step) -> Void) {
        port = SerialPort(path: path)
        self.progress = progress
    }

    /// Where the firmware found on the board is saved before it is overwritten.
    static var backupFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ledly/Backups", isDirectory: true)
    }

    /// Blocking; run off the main thread. Saves the current firmware to `backupFolder` first.
    func flash(hex: String) throws {
        let image = try Self.parseHex(hex)
        guard image.count <= Self.flashLimit else { throw FlashError.tooBig(image.count) }
        defer { port.close() }

        progress(.connecting)
        try connect()
        try checkSignature()
        _ = try command([0x50], step: "enter")
        try saveBackup()

        let pages = stride(from: 0, to: image.count, by: Self.pageSize).map { $0 }
        for (n, address) in pages.enumerated() {
            let page = Array(image[address..<min(address + Self.pageSize, image.count)])
            try loadAddress(address)
            let size = page.count
            _ = try command([0x64, UInt8(size >> 8), UInt8(size & 0xFF), 0x46] + page, step: "write")
            progress(.writing(Double(n + 1) / Double(pages.count)))
        }
        for (n, address) in pages.enumerated() {
            let expected = Array(image[address..<min(address + Self.pageSize, image.count)])
            try loadAddress(address)
            let size = expected.count
            let read = try command([0x74, UInt8(size >> 8), UInt8(size & 0xFF), 0x46], replyLength: size, step: "read")
            if read != expected {
                let index = zip(read, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? 0
                throw FlashError.verify(address + index)
            }
            progress(.verifying(Double(n + 1) / Double(pages.count)))
        }
        _ = try? command([0x51], step: "leave")
        progress(.done)
    }

    /// Reads the whole application area without writing anything (`Ledly --read-flash <port> <file.hex>`).
    func readFlash() throws -> [UInt8] {
        defer { port.close() }
        try connect()
        try checkSignature()
        _ = try command([0x50], step: "enter")
        let data = try readImage()
        _ = try? command([0x51], step: "leave")
        return data
    }

    private func checkSignature() throws {
        let signature = try command([0x75], replyLength: 3, step: "signature")
        // 1E 95 0F = ATmega328P, 1E 95 14 = ATmega328.
        guard signature[0] == 0x1E, signature[1] == 0x95, signature[2] == 0x0F || signature[2] == 0x14 else {
            throw FlashError.wrongChip(signature.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
    }

    /// Application flash with trailing erased (0xFF) bytes trimmed.
    private func readImage() throws -> [UInt8] {
        var data: [UInt8] = []
        for address in stride(from: 0, to: Self.flashLimit, by: Self.pageSize) {
            try loadAddress(address)
            data += try command([0x74, 0, UInt8(Self.pageSize), 0x46], replyLength: Self.pageSize, step: "read")
            progress(.backingUp(Double(address + Self.pageSize) / Double(Self.flashLimit)))
        }
        while data.last == 0xFF { data.removeLast() }
        return data
    }

    private func saveBackup() throws {
        let data = try readImage()
        guard !data.isEmpty else { return }
        let folder = Self.backupFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withDashSeparatorInDate])
        let url = folder.appendingPathComponent("nano-\(stamp).hex")
        try Self.makeHex(data).write(to: url, atomically: true, encoding: .utf8)
    }

    private func connect() throws {
        for baud in [115_200, 57_600] {
            for _ in 0..<2 {
                try port.open(baud: baud)
                resetBoard()
                for _ in 0..<6 {
                    port.flushInput()
                    try port.write([0x30, Self.syncCRC])
                    let reply = port.read(max: 2, timeout: 0.25)
                    if reply.count >= 1, reply.first == Self.inSync {
                        // Drain the rest and sync once more to be sure we're aligned.
                        _ = port.read(max: 16, timeout: 0.05)
                        port.flushInput()
                        if (try? command([0x30], step: "sync")) != nil { return }
                    }
                }
                port.close()
            }
        }
        throw FlashError.noBootloader
    }

    /// Pulses DTR/RTS: the Nano's reset is wired to DTR through a capacitor.
    private func resetBoard() {
        port.setDTR(false)
        usleep(250_000)
        port.setDTR(true)
        usleep(50_000)
    }

    private func loadAddress(_ byteAddress: Int) throws {
        let word = byteAddress / 2
        _ = try command([0x55, UInt8(word & 0xFF), UInt8(word >> 8)], step: "address")
    }

    /// Sends `body` + CRC_EOP and expects INSYNC, `replyLength` bytes, OK.
    private func command(_ body: [UInt8], replyLength: Int = 0, step: String) throws -> [UInt8] {
        try port.write(body + [Self.syncCRC])
        let reply: [UInt8]
        do {
            reply = try port.readExactly(replyLength + 2, timeout: 1)
        } catch {
            throw FlashError.protocolError(step)
        }
        guard reply.first == Self.inSync, reply.last == Self.ok else { throw FlashError.protocolError(step) }
        return Array(reply[1..<(1 + replyLength)])
    }

    /// Flat image → Intel HEX (16-byte data records).
    static func makeHex(_ data: [UInt8]) -> String {
        var lines: [String] = []
        for start in stride(from: 0, to: data.count, by: 16) {
            let chunk = Array(data[start..<min(start + 16, data.count)])
            let record = [UInt8(chunk.count), UInt8(start >> 8 & 0xFF), UInt8(start & 0xFF), 0] + chunk
            let checksum = UInt8(truncatingIfNeeded: 256 - Int(record.reduce(0) { $0 &+ $1 }))
            lines.append(":" + (record + [checksum]).map { String(format: "%02X", $0) }.joined())
        }
        lines.append(":00000001FF")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Intel HEX → flat image starting at address 0, padded with 0xFF.
    static func parseHex(_ text: String) throws -> [UInt8] {
        var memory: [Int: UInt8] = [:]
        var base = 0
        for (index, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard line.hasPrefix(":"), line.count >= 11, line.count % 2 == 1 else { throw FlashError.badHex(index + 1) }
            var bytes: [UInt8] = []
            var i = line.index(after: line.startIndex)
            while i < line.endIndex {
                let j = line.index(i, offsetBy: 2)
                guard let b = UInt8(line[i..<j], radix: 16) else { throw FlashError.badHex(index + 1) }
                bytes.append(b)
                i = j
            }
            let length = Int(bytes[0])
            guard bytes.count == length + 5 else { throw FlashError.badHex(index + 1) }
            guard bytes.reduce(0, { $0 &+ $1 }) == 0 else { throw FlashError.badHex(index + 1) }
            let address = Int(bytes[1]) << 8 | Int(bytes[2])
            let data = bytes[4..<(4 + length)]
            switch bytes[3] {
            case 0x00:
                for (k, b) in data.enumerated() { memory[base + address + k] = b }
            case 0x01:
                break
            case 0x02:
                base = (Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])) << 4
            case 0x04:
                base = (Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])) << 16
            default:
                continue
            }
        }
        guard let top = memory.keys.max() else { return [] }
        var image = [UInt8](repeating: 0xFF, count: top + 1)
        for (address, b) in memory { image[address] = b }
        return image
    }
}
