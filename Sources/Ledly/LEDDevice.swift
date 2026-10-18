import Foundation

/// Connection to the Arduino that drives the strip (Adalight protocol).
/// Only used from the engine queue.
extension LEDDevice.Status {
    var isConnectedStatus: Bool { if case .connected = self { return true } else { return false } }
}

final class LEDDevice {
    enum Status: Equatable {
        case disconnected
        case connecting
        /// `firmware` is the hello line ("Ada Ledly 2 pin 6 max 400 baud 1000000"), nil for a silent Adalight sketch.
        case connected(firmware: String?)
        case failed(String)
    }

    private(set) var status: Status = .disconnected
    private var port: SerialPort?
    /// Ledly firmware answers 'k' after each frame; we wait for it before sending the next.
    private var acknowledges = false
    private var awaitingAck = false
    private var lastSend = Date.distantPast
    private(set) var framesSent = 0

    var path: String? { port?.path }
    var isConnected: Bool { if case .connected = status { return true } else { return false } }

    /// Rate that last produced a hello: tried first next time, so reconnecting usually takes one reset.
    private var lastBaud = Firmware.baud

    /// Blocking: resets the Nano and waits up to ~2.5 s per baud rate for its hello.
    /// Tries the current firmware's rate and the older ones (v1 ran at 500000).
    func connect(path: String) {
        disconnect()
        status = .connecting
        var rates = [lastBaud]
        for rate in [Firmware.baud] + Firmware.legacyBauds where !rates.contains(rate) { rates.append(rate) }
        var hello: String?
        for rate in rates {
            let port = SerialPort(path: path)
            do {
                try port.open(baud: rate)
            } catch {
                status = .failed(error.localizedDescription)
                return
            }
            hello = Self.waitForHello(port)
            if hello != nil {
                lastBaud = rate
                self.port = port
                break
            }
            port.close()
        }
        if hello == nil {
            // A silent Adalight sketch (not ours): assume the current rate.
            let port = SerialPort(path: path)
            do {
                try port.open(baud: Firmware.baud)
            } catch {
                status = .failed(error.localizedDescription)
                return
            }
            self.port = port
        }
        acknowledges = hello?.contains("Ledly") == true
        awaitingAck = false
        status = .connected(firmware: hello)
    }

    /// Resets the Nano so our sketch says hello; the bootloader runs for ~1 s first. Opening the
    /// port already pulses DTR, but not when it was closed a moment ago, so pulse it explicitly.
    private static func waitForHello(_ port: SerialPort) -> String? {
        port.setDTR(false)
        usleep(100_000)
        port.setDTR(true)
        port.flushInput()
        let deadline = Date().addingTimeInterval(2.5)
        while deadline.timeIntervalSinceNow > 0 {
            if let line = port.readLine(timeout: deadline.timeIntervalSinceNow), line.hasPrefix("Ada") {
                return line
            }
        }
        return nil
    }

    /// "Ada Ledly 2 pin 6 max 400 baud 1000000" → 2. nil for other Adalight firmware.
    static func ledlyVersion(_ hello: String?) -> Int? {
        guard let parts = hello?.split(separator: " "), parts.count >= 3, parts[1] == "Ledly" else { return nil }
        return Int(parts[2])
    }

    /// "… pin 6 …" → 6.
    static func ledlyPin(_ hello: String?) -> Int? {
        guard let parts = hello?.split(separator: " "), let i = parts.firstIndex(of: "pin"), i + 1 < parts.count else { return nil }
        return Int(parts[i + 1])
    }

    func disconnect() {
        port?.close()
        port = nil
        if status != .disconnected { status = .disconnected }
    }

    /// Returns false if the frame was skipped because the device is still busy.
    @discardableResult
    func send(_ colors: [RGB]) -> Bool {
        guard let port, isConnected, !colors.isEmpty else { return false }
        if awaitingAck {
            let reply = port.read(max: 64, timeout: 0)
            if reply.contains(0x6B) { // 'k'
                awaitingAck = false
            } else if Date().timeIntervalSince(lastSend) < 0.25 {
                return false
            } else {
                // Lost ack (or the board rebooted): carry on.
                awaitingAck = false
            }
        }
        let count = colors.count - 1
        let hi = UInt8(count >> 8 & 0xFF), lo = UInt8(count & 0xFF)
        var frame: [UInt8] = [0x41, 0x64, 0x61, hi, lo, hi ^ lo ^ 0x55]
        frame.reserveCapacity(6 + colors.count * 3)
        for c in colors {
            frame.append(UInt8(c.r8)); frame.append(UInt8(c.g8)); frame.append(UInt8(c.b8))
        }
        do {
            try port.write(frame)
        } catch {
            status = .failed(error.localizedDescription)
            port.close()
            self.port = nil
            return false
        }
        lastSend = Date()
        framesSent += 1
        awaitingAck = acknowledges
        return true
    }
}
