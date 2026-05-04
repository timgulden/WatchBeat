import Foundation
import Network

/// Minimal SNTP (RFC 4330) client for measuring true wall time independent
/// of iOS's system clock. Used by the calibration tool to measure the
/// iPhone's audio sample clock against an external time reference.
///
/// We use SNTP rather than HTTP Date headers because HTTP Date has
/// 1-second resolution; over a 10-minute calibration window we need
/// sub-100 ms precision to measure a few-hundred-ppm crystal offset.
/// SNTP gives us low-millisecond precision per query.
///
/// Single-shot query design: send one packet, wait for response, return
/// the result. No retries, no continuous discipline. The caller is
/// expected to retry on timeout.
enum NTPError: Error {
    case timeout
    case badResponse
    case noConnection
}

/// Result of one SNTP query.
///
/// `serverTime` is the server's "transmit timestamp" — the moment the
/// server stamped its outgoing packet, in seconds since the Unix epoch.
/// `clientReceiveTime` is the client's `mach_continuous_time()`-derived
/// timestamp at the moment the response was received locally; same
/// monotonic clock the audio engine's host time uses.
/// `roundTripSeconds` is the measured network round trip; half of this
/// is the residual uncertainty in `serverTime` (assuming symmetric path).
struct NTPResult {
    let serverTime: Double           // Unix seconds, fractional
    let clientReceiveTime: Double    // monotonic seconds (mach_continuous_time)
    let roundTripSeconds: Double
}

/// Issues one SNTP query against the given host:port and returns the
/// result via the completion handler. Default port 123, default timeout
/// 5 seconds.
func ntpQuery(host: String,
              port: UInt16 = 123,
              timeout: TimeInterval = 5.0,
              completion: @escaping (Result<NTPResult, NTPError>) -> Void) {
    let endpoint = NWEndpoint.Host(host)
    let nwPort = NWEndpoint.Port(rawValue: port)!
    let conn = NWConnection(host: endpoint, port: nwPort, using: .udp)

    var didComplete = false
    let lock = NSLock()
    func finish(_ result: Result<NTPResult, NTPError>) {
        lock.lock(); defer { lock.unlock() }
        if didComplete { return }
        didComplete = true
        conn.cancel()
        completion(result)
    }

    // Build the SNTP request packet:
    //   byte 0 = LI(0) | VN(4) | mode(3 client) = 0b00100011 = 0x23
    //   bytes 1..47 = zeros (server fills in receive/transmit timestamps)
    var packet = Data(count: 48)
    packet[0] = 0x23

    conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
            let sendTime = monotonicSeconds()
            conn.send(content: packet, completion: .contentProcessed { sendErr in
                if sendErr != nil { finish(.failure(.noConnection)); return }
                conn.receiveMessage { (data, _, _, recvErr) in
                    let recvTime = monotonicSeconds()
                    if recvErr != nil || data == nil || data!.count < 48 {
                        finish(.failure(.badResponse))
                        return
                    }
                    // Transmit timestamp is bytes 40..47 of the response.
                    // 4 bytes seconds (since 1900-01-01) + 4 bytes fraction.
                    let bytes = data!
                    let secsBE = bytes.subdata(in: 40..<44)
                    let fracBE = bytes.subdata(in: 44..<48)
                    let secs1900 = UInt32(bigEndian: secsBE.withUnsafeBytes { $0.load(as: UInt32.self) })
                    let frac     = UInt32(bigEndian: fracBE.withUnsafeBytes { $0.load(as: UInt32.self) })
                    // Convert to Unix epoch.
                    let serverUnix = Double(secs1900) - 2208988800.0 + Double(frac) / 4294967296.0
                    let rtt = recvTime - sendTime
                    finish(.success(NTPResult(serverTime: serverUnix,
                                              clientReceiveTime: recvTime,
                                              roundTripSeconds: rtt)))
                }
            })
        case .failed:
            finish(.failure(.noConnection))
        case .cancelled:
            // Already finished — nothing to do.
            break
        default:
            break
        }
    }

    conn.start(queue: .global(qos: .userInitiated))

    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        finish(.failure(.timeout))
    }
}

/// Monotonic wall-clock seconds (continuous across sleep). This is the
/// reference we anchor audio sample times to. It uses the same kernel
/// timebase that `AVAudioTime.hostTime` is reported in, so the two are
/// directly comparable.
func monotonicSeconds() -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let host = mach_continuous_time()
    let nanos = Double(host) * Double(info.numer) / Double(info.denom)
    return nanos / 1e9
}
