import Foundation
import IOKit
import IOKit.serial

/// A serial port found in the IORegistry.
struct SerialPortInfo: Identifiable, Hashable {
    let path: String          // /dev/cu.usbserial-3110
    let name: String          // "USB Serial"
    let vendorID: Int?
    let productID: Int?

    var id: String { path }

    /// Chips used on Arduino Nano boards and clones.
    var looksLikeArduino: Bool {
        switch (vendorID, productID) {
        case (0x1A86, _): return true            // WCH CH340/CH341
        case (0x2341, _), (0x2A03, _): return true // Arduino
        case (0x0403, 0x6001): return true       // FTDI FT232R (original Nano)
        case (0x10C4, 0xEA60): return true       // CP210x
        default: return false
        }
    }

    var detail: String {
        guard let vendorID, let productID else { return path }
        return String(format: "%@ · %04X:%04X", path, vendorID, productID)
    }

    static func list() -> [SerialPortInfo] {
        var result: [SerialPortInfo] = []
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString,
                                                             kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            else { continue }
            func parent(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            let vendor = parent("idVendor") as? Int
            let product = parent("idProduct") as? Int
            // Only USB adapters: skips Bluetooth and the debug console.
            guard vendor != nil else { continue }
            let name = (parent("USB Product Name") as? String) ?? (parent("kUSBProductString") as? String) ?? "USB"
            result.append(SerialPortInfo(path: path, name: name, vendorID: vendor, productID: product))
        }
        return result.sorted { ($0.looksLikeArduino ? 0 : 1, $0.path) < ($1.looksLikeArduino ? 0 : 1, $1.path) }
    }
}

enum SerialError: LocalizedError {
    case open(String, Int32)
    case configure(Int32)
    case write(Int32)
    case timeout

    var errorDescription: String? {
        switch self {
        case .open(let path, let code): return tr("No se pudo abrir %@: %@", path, String(cString: strerror(code)))
        case .configure(let code): return tr("No se pudo configurar el puerto: %@", String(cString: strerror(code)))
        case .write(let code): return tr("Error al escribir en el puerto: %@", String(cString: strerror(code)))
        case .timeout: return tr("El dispositivo no responde.")
        }
    }
}

/// Raw 8N1 serial port on a POSIX file descriptor. Not thread-safe: use it from one queue.
final class SerialPort {
    let path: String
    private(set) var fd: Int32 = -1

    init(path: String) {
        self.path = path
    }

    deinit { close() }

    var isOpen: Bool { fd >= 0 }

    /// Opening the port raises DTR, which resets an Arduino.
    func open(baud: Int) throws {
        close()
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { throw SerialError.open(path, errno) }
        fd = handle
        do {
            guard ioctl(fd, TIOCEXCL) == 0 else { throw SerialError.configure(errno) }
            // Back to blocking; reads use select() with a timeout.
            _ = fcntl(fd, F_SETFL, 0)
            var options = termios()
            guard tcgetattr(fd, &options) == 0 else { throw SerialError.configure(errno) }
            cfmakeraw(&options)
            options.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8)
            options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
            options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
            cfsetspeed(&options, speed_t(B9600))
            guard tcsetattr(fd, TCSANOW, &options) == 0 else { throw SerialError.configure(errno) }
            try setBaud(baud)
        } catch {
            close()
            throw error
        }
    }

    /// Any rate the driver supports (500000, 1000000…), not only the termios constants.
    func setBaud(_ baud: Int) throws {
        var speed = speed_t(baud)
        // IOSSIOSPEED = _IOW('T', 2, speed_t)
        let iossiospeed: UInt = 0x8008_5402
        guard ioctl(fd, iossiospeed, &speed) == 0 else { throw SerialError.configure(errno) }
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    func setDTR(_ on: Bool) {
        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, on ? UInt(TIOCMBIS) : UInt(TIOCMBIC), &bits)
    }

    /// Discards anything received but not read yet.
    func flushInput() {
        tcflush(fd, TCIFLUSH)
    }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress! + offset, bytes.count - offset)
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw SerialError.write(errno)
            }
            offset += n
        }
    }

    /// Reads up to `count` bytes, waiting at most `timeout` seconds for the first one.
    func read(max count: Int, timeout: TimeInterval) -> [UInt8] {
        guard fd >= 0, waitReadable(timeout) else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, count) }
        return n > 0 ? Array(buffer[0..<n]) : []
    }

    /// Reads exactly `count` bytes or throws on timeout.
    func readExactly(_ count: Int, timeout: TimeInterval) throws -> [UInt8] {
        var result: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while result.count < count {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw SerialError.timeout }
            result += read(max: count - result.count, timeout: left)
        }
        return result
    }

    /// Reads one text line (without the newline), or nil on timeout.
    func readLine(timeout: TimeInterval) -> String? {
        var line: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            let chunk = read(max: 1, timeout: deadline.timeIntervalSinceNow)
            guard let byte = chunk.first else { continue }
            if byte == 0x0A { return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            line.append(byte)
            if line.count > 200 { line.removeFirst(100) }
        }
        return nil
    }

    private func waitReadable(_ timeout: TimeInterval) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, Int32(max(0, timeout) * 1000)) > 0
    }
}
