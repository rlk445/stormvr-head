import Foundation
import Combine
import CoreMotion
import Darwin

/// Le a orientacao do iPhone e envia ao driver StormVR (UDP, porta 5556) o pacote KbtHeadPacket de 60 bytes
/// (formato identico ao PoseSender.kt do app Android / protocol.h do driver).
final class HeadSender: ObservableObject {
    @Published var running = false
    @Published var status = "Parado"
    @Published var packetsPerSec = 0
    @Published var yaw = 0.0
    @Published var pitch = 0.0
    @Published var roll = 0.0

    static let port = 5556
    private static let magic: UInt32 = 0x31485453          // "STH1"

    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var dest = sockaddr_in()
    private var seq: UInt32 = 0
    private var session: UInt32 = 1
    private var recenterCount: UInt32 = 0
    private var topRight = true
    private var winCount = 0
    private var winStart = Date()
    private let deviceId: UInt32 = {
        let k = "deviceId"
        let v = UserDefaults.standard.integer(forKey: k)
        if v != 0 { return UInt32(truncatingIfNeeded: v) }
        let n = Int.random(in: 1...0x7fffffff)
        UserDefaults.standard.set(n, forKey: k)
        return UInt32(n)
    }()

    func start(host: String, hz: Int, topRight: Bool) {
        stop()
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(HeadSender.port).bigEndian
        let h = host.trimmingCharacters(in: .whitespaces)
        guard inet_pton(AF_INET, h, &a.sin_addr) == 1 else { status = "IP invalido (use algo como 192.168.0.10)"; return }
        guard motion.isDeviceMotionAvailable else { status = "Sem sensor de movimento"; return }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { status = "Nao consegui abrir o socket"; return }
        var tos: Int32 = 0x10
        setsockopt(s, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))

        lock.lock()
        fd = s; dest = a; seq = 0; self.topRight = topRight
        session = UInt32.random(in: 1...0x7fffffff)
        winCount = 0; winStart = Date()
        lock.unlock()

        KeepAlive.shared.start()
        motion.deviceMotionUpdateInterval = 1.0 / Double(max(30, min(100, hz)))
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] dm, _ in
            if let dm = dm { self?.handle(dm) }
        }
        running = true
        status = "Enviando para \(h):\(HeadSender.port)"
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        KeepAlive.shared.stop()
        lock.lock()
        if fd >= 0 { close(fd); fd = -1 }
        lock.unlock()
        running = false
        packetsPerSec = 0
        if status.hasPrefix("Enviando") { status = "Parado" }
    }

    func recenter() { lock.lock(); recenterCount &+= 1; lock.unlock() }
    func setTopRight(_ v: Bool) { lock.lock(); topRight = v; lock.unlock() }

    private struct Writer {
        var bytes = [UInt8]()
        mutating func put<T>(_ v: T) { withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) } }
    }

    private func handle(_ dm: CMDeviceMotion) {
        lock.lock()
        let s = fd, tr = topRight, rc = recenterCount, sq = seq, sess = session
        var d = dest
        seq &+= 1
        lock.unlock()
        guard s >= 0 else { return }

        let q = HeadMath.quaternion(from: dm.attitude.rotationMatrix, topRight: tr)
        var w = Writer()
        w.bytes.reserveCapacity(60)
        w.put(HeadSender.magic)
        w.put(deviceId)
        w.put(sess)
        w.put(sq)
        w.put(UInt64(max(0, dm.timestamp) * 1_000_000))   // relogio do aparelho, em microssegundos
        w.put(UInt16(0))                                   // flags
        w.put(UInt8(0))                                    // trackingMode 0 = 3DoF
        w.put(UInt8(0))
        w.put(Float(q.w)); w.put(Float(q.x)); w.put(Float(q.y)); w.put(Float(q.z))
        w.put(rc)                                          // recenterCount
        w.put(Float(0)); w.put(Float(0)); w.put(Float(0))  // pos[]
        let bytes = w.bytes
        _ = bytes.withUnsafeBytes { buf in
            withUnsafePointer(to: &d) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(s, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        winCount += 1
        let now = Date()
        if now.timeIntervalSince(winStart) >= 0.5 {
            let rate = Int(Double(winCount) / now.timeIntervalSince(winStart))
            winCount = 0; winStart = now
            let e = HeadMath.eulerDegrees(q)
            DispatchQueue.main.async {
                self.packetsPerSec = rate
                self.yaw = e.yaw; self.pitch = e.pitch; self.roll = e.roll
            }
        }
    }
}
