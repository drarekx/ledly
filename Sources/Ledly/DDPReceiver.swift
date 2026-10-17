import Foundation
import Network

/// Receives LED frames over DDP (Distributed Display Protocol, UDP, port 4048 by default),
/// the way WLED does. No authentication, like WLED.
///
/// Header (10 bytes, 14 with a timecode), multi-byte fields big-endian:
///   0  flags     0x40 = version 1, 0x01 = push (show the frame), 0x10 = timecode present
///   1  sequence  low 4 bits
///   2  type      0x0B = RGB 8 bit (0x01 and 0x00 are accepted as RGB too)
///   3  dest. ID  1 = default output (255 = all)
///   4  offset    32 bits, in bytes from the first LED
///   8  length    16 bits, data bytes in this packet
/// A frame may span several packets; it is shown when the one with "push" arrives.
final class DDPReceiver {
    /// Called on the receiver's queue with the frame's bytes (R, G, B per LED from LED 0) and the sender.
    var onFrame: ((_ bytes: [UInt8], _ from: String) -> Void)?

    private static let maxBytes = 65_535 * 3
    private let queue = DispatchQueue(label: "ledly.ddp", qos: .userInteractive)
    private var listener: NWListener?
    private var buffer: [UInt8] = []
    /// Highest byte written since the last push.
    private var written = 0

    enum Status: Equatable {
        case stopped, running(port: Int), failed(String)
    }

    var onStatus: ((Status) -> Void)?

    /// `localOnly` binds to the loopback interface, like the HTTP API.
    func start(port: Int, localOnly: Bool) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let listener: NWListener
            if localOnly {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
                listener = try NWListener(using: parameters)
            } else {
                listener = try NWListener(using: parameters, on: nwPort)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onStatus?(.running(port: port))
                case .failed(let error): self?.onStatus?(.failed(error.localizedDescription))
                default: break
                }
            }
            // UDP "connections" are one per sender address.
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStatus?(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onStatus?(.stopped)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handle(data, from: Self.host(of: connection.endpoint))
            }
            if error == nil {
                self.receive(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func handle(_ packet: Data, from sender: String) {
        let bytes = [UInt8](packet)
        guard bytes.count >= 10 else { return }
        let flags = bytes[0]
        guard flags & 0xC0 == 0x40 else { return }           // version 1
        guard flags & 0x02 == 0 else { return }              // queries aren't answered
        let type = bytes[2]
        guard type == 0x0B || type == 0x01 || type == 0x00 else { return }
        let destination = bytes[3]
        guard destination == 1 || destination == 255 else { return }
        let offset = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        let length = Int(bytes[8]) << 8 | Int(bytes[9])
        let header = flags & 0x10 != 0 ? 14 : 10
        let payload = min(length, bytes.count - header)
        guard payload >= 0, offset + payload <= Self.maxBytes else { return }

        if buffer.count < offset + payload { buffer += [UInt8](repeating: 0, count: offset + payload - buffer.count) }
        buffer.replaceSubrange(offset..<(offset + payload), with: bytes[header..<(header + payload)])
        written = max(written, offset + payload)

        if flags & 0x01 != 0 {
            onFrame?(Array(buffer[0..<written]), sender)
            written = 0
        }
    }

    private static func host(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let address): return "\(address)"
            case .ipv6(let address): return "\(address)"
            case .name(let name, _): return name
            @unknown default: return "\(host)"
            }
        }
        return "\(endpoint)"
    }
}
