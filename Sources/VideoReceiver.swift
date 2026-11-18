import Foundation
import Combine
import UIKit
import Network

/// Conecta no stormvr_video.py (TCP 5558) e recebe quadros JPEG: [uint32 LE tamanho][bytes JPEG].
final class VideoReceiver: ObservableObject {
    @Published var image: UIImage?
    @Published var status = "Desligado"
    @Published var fps = 0

    static let port: UInt16 = 5558
    private var conn: NWConnection?
    private let q = DispatchQueue(label: "stormvr.video")
    private var buffer = Data()
    private var active = false
    private var host = ""
    private var frames = 0
    private var winStart = Date()

    func start(host: String) {
        stop()
        self.host = host.trimmingCharacters(in: .whitespaces)
        active = true
        connect()
    }

    func stop() {
        active = false
        conn?.cancel(); conn = nil
        buffer.removeAll()
        DispatchQueue.main.async { self.status = "Desligado"; self.fps = 0 }
    }

    private func connect() {
        guard active else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: VideoReceiver.port)!, using: .tcp)
        conn = c
        buffer.removeAll()
        DispatchQueue.main.async { self.status = "Conectando em \(self.host):\(VideoReceiver.port)..." }
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self, self.conn === c else { return }
            switch st {
            case .ready:
                DispatchQueue.main.async { self.status = "Video conectado" }
                self.read(c)
            case .failed, .cancelled:
                self.retry(c)
            case .waiting:
                DispatchQueue.main.async { self.status = "Sem resposta do PC (stormvr_video.py rodando? firewall?)" }
            default: break
            }
        }
        c.start(queue: q)
    }

    private func retry(_ c: NWConnection) {
        guard active, conn === c else { return }
        c.cancel()
        q.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.connect() }
    }

    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self = self, self.conn === c else { return }
            if let d = data, !d.isEmpty { self.buffer.append(d); self.drain() }
            if done || err != nil { self.retry(c); return }
            self.read(c)
        }
    }

    /// Extrai todos os quadros completos e mostra so o mais recente (descarta atraso acumulado).
    private func drain() {
        var latest: Data?
        while buffer.count >= 4 {
            let n = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
            if n <= 0 || n > 20_000_000 { buffer.removeAll(); return }
            if buffer.count < 4 + n { break }
            latest = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + n)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + n)
        }
        guard let jpg = latest, let img = UIImage(data: jpg) else { return }
        frames += 1
        let now = Date()
        var rate: Int?
        if now.timeIntervalSince(winStart) >= 1 {
            rate = Int(Double(frames) / now.timeIntervalSince(winStart)); frames = 0; winStart = now
        }
        DispatchQueue.main.async {
            self.image = img
            if let r = rate { self.fps = r }
        }
    }
}
