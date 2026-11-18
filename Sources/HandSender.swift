import Foundation
import AVFoundation
import Vision
import Combine
import simd
import Darwin

/// Filtro One Euro (mesmo do HandTracker.kt): tira o tremor com a mao parada e quase nao atrasa quando ela se move.
final class OneEuro3 {
    private var xPrev = SIMD3<Float>(repeating: 0)
    private var dxPrev = SIMD3<Float>(repeating: 0)
    private var tPrev: Float = 0
    private var inited = false
    private let minCutoff: Float, beta: Float, dCutoff: Float

    init(minCutoff: Float, beta: Float, dCutoff: Float) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }

    func reset() { inited = false }

    private func alpha(_ cutoff: Float, _ dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    func apply(_ x: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        if !inited { xPrev = x; dxPrev = SIMD3<Float>(repeating: 0); tPrev = t; inited = true; return x }
        let dt = max(t - tPrev, 1e-3)
        tPrev = t
        let aD = alpha(dCutoff, dt)
        var out = x
        for i in 0..<3 {
            let dx = (x[i] - xPrev[i]) / dt
            let dxh = aD * dx + (1 - aD) * dxPrev[i]
            dxPrev[i] = dxh
            let a = alpha(minCutoff + beta * abs(dxh), dt)
            let xh = a * x[i] + (1 - a) * xPrev[i]
            xPrev[i] = xh
            out[i] = xh
        }
        return out
    }
}

/// Rastreia as MAOS pela camera traseira do iPhone (Vision) e envia ao driver StormVR o pacote KBH1 (UDP 5557, 92 bytes),
/// identico ao PcLink.kt do app Android / protocol.h do driver: posicao do centro da palma e direcao do pulso para o dedo medio,
/// relativas a cabeca e alinhadas so ao giro (yaw) dela (x direita, y cima, z para tras), mais a pinca (polegar + indicador).
///
/// IMPORTANTE (limite do iOS): a camera so funciona com o StormVR Head NA TELA. Com o Moonlight na frente o iOS desliga a camera.
/// Por isso o video precisa ser visto pelo botao "Abrir VIDEO" do proprio app.
final class HandSender: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var running = false
    @Published var status = "Parado"
    @Published var info = ""

    static let port = 5557
    private static let magic: UInt32 = 0x3148424B           // "KBH1"
    private static let palmLen: Float = 0.095               // pulso -> base do dedo medio (m), mao adulta media

    // ---- ajustes (lidos em outras threads, sempre sob lock)
    private let lock = NSLock()
    private var topRight = true
    private var handScale: Float = 1.0
    private var pinchOn: Float = 0.40

    func setTopRight(_ v: Bool) { lock.lock(); topRight = v; lock.unlock() }
    func setHandScale(_ v: Float) { lock.lock(); handScale = v; lock.unlock() }
    func setPinchOn(_ v: Float) { lock.lock(); pinchOn = v; lock.unlock() }

    // ---- rede
    private var fd: Int32 = -1
    private var dest = sockaddr_in()
    private var seq: UInt32 = 0
    private var session: UInt32 = 1
    private let deviceId: UInt32 = {
        let k = "deviceId"
        let v = UserDefaults.standard.integer(forKey: k)
        if v != 0 { return UInt32(truncatingIfNeeded: v) }
        let n = Int.random(in: 1...0x7fffffff)
        UserDefaults.standard.set(n, forKey: k)
        return UInt32(n)
    }()

    // ---- camera
    private let sessionQueue = DispatchQueue(label: "stormvr.hand.session")
    private let videoQueue = DispatchQueue(label: "stormvr.hand.video", qos: .userInteractive)
    private let sendQueue = DispatchQueue(label: "stormvr.hand.send", qos: .userInteractive)
    private var capture: AVCaptureSession?
    private var fovDeg: Float = 65
    private var timer: DispatchSourceTimer?
    private weak var head: HeadSender?
    private var generation = 0

    // ---- estado por mao (0 = esquerda, 1 = direita)
    private final class Slot {
        var active = false
        var conf = 0
        var world = SIMD3<Float>(repeating: 0)
        var aim = SIMD3<Float>(0, 0, -1)
        var lastSeen = 0.0
        var lastT: Double = 0
        var pinch = false
        var pinchMin: Float = 1
        var offCount = 0
        var ratio: Float = 1
        var ratioVel: Float = 0
        var depth: Float = 0
        let fPos = OneEuro3(minCutoff: 2.2, beta: 28, dCutoff: 1)
        let fAim = OneEuro3(minCutoff: 2.2, beta: 10, dCutoff: 1)
        func reset() {
            active = false; conf = 0; pinch = false; pinchMin = 1; offCount = 0
            ratio = 1; ratioVel = 0; fPos.reset(); fAim.reset()
        }
    }
    private let slots = [Slot(), Slot()]
    private var swapVotes = 0                       // > 0: o rotulo (esquerda/direita) do Vision veio invertido
    private let startT = ProcessInfo.processInfo.systemUptime
    private var lastFwd = SIMD2<Float>(0, -1)       // frente da cabeca no plano horizontal (x, z do SteamVR)
    private var frames = 0
    private var fpsWin = ProcessInfo.processInfo.systemUptime
    private var fps = 0
    private var packets = 0
    private var lastInfo = 0.0

    // ------------------------------------------------------------------ iniciar / parar
    func start(host: String, head: HeadSender, topRight: Bool, handScale: Float, pinchOn: Float) {
        stop()
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(HandSender.port).bigEndian
        let h = host.trimmingCharacters(in: .whitespaces)
        guard inet_pton(AF_INET, h, &a.sin_addr) == 1 else { status = "IP invalido para as maos"; return }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { status = "Nao consegui abrir o socket das maos"; return }
        var tos: Int32 = 0x10
        setsockopt(s, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))

        lock.lock()
        fd = s; dest = a; seq = 0
        session = UInt32.random(in: 1...0x7fffffff)
        self.topRight = topRight; self.handScale = handScale; self.pinchOn = pinchOn
        generation += 1
        let gen = generation
        lock.unlock()
        self.head = head
        for sl in slots { sl.reset() }
        swapVotes = 0
        status = "Pedindo acesso a camera..."
        running = true

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard granted else {
                    self.status = "Sem permissao da camera (Ajustes > StormVR Head > Camera)"
                    self.running = false
                    return
                }
                self.sessionQueue.async { self.configureAndRun(gen) }
            }
        }
        startSendTimer()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVCaptureSession.wasInterruptedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interruptionEnded(_:)),
                                               name: AVCaptureSession.interruptionEndedNotification, object: nil)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        timer?.cancel(); timer = nil
        lock.lock()
        generation += 1
        let cap = capture
        capture = nil
        if fd >= 0 { close(fd); fd = -1 }
        lock.unlock()
        sessionQueue.async { cap?.stopRunning() }
        running = false
        info = ""
        if status != "Parado" && !status.hasPrefix("Sem permissao") { status = "Parado" }
    }

    @objc private func interrupted(_ n: Notification) {
        DispatchQueue.main.async { self.status = "Camera pausada: o iOS so libera a camera com o StormVR Head na tela" }
    }

    @objc private func interruptionEnded(_ n: Notification) {
        DispatchQueue.main.async { self.status = "Camera ativa" }
    }

    private func configureAndRun(_ gen: Int) {
        lock.lock(); let ok = gen == generation; lock.unlock()
        guard ok else { return }
        let s = AVCaptureSession()
        s.beginConfiguration()
        s.sessionPreset = .vga640x480
        s.automaticallyConfiguresApplicationAudioSession = false       // nao mexe no audio (KeepAlive)
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev), s.canAddInput(input) else {
            s.commitConfiguration()
            DispatchQueue.main.async { self.status = "Nao consegui abrir a camera traseira"; self.running = false }
            return
        }
        s.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.setSampleBufferDelegate(self, queue: videoQueue)
        guard s.canAddOutput(out) else {
            s.commitConfiguration()
            DispatchQueue.main.async { self.status = "Nao consegui ler os quadros da camera"; self.running = false }
            return
        }
        s.addOutput(out)
        if let c = out.connection(with: .video), c.isCameraIntrinsicMatrixDeliverySupported {
            c.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
        s.commitConfiguration()
        do {
            try dev.lockForConfiguration()
            dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            dev.unlockForConfiguration()
        } catch {}
        let fov = dev.activeFormat.videoFieldOfView
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        fovDeg = fov > 20 ? fov : 65
        capture = s
        lock.unlock()
        s.startRunning()
        DispatchQueue.main.async { self.status = "Camera ativa (procurando maos)" }
    }

    // ------------------------------------------------------------------ quadro da camera -> maos
    private struct Det {
        var palm: SIMD3<Float>           // centro da palma, referencial "mundo" do SteamVR (cabeca na origem)
        var aim: SIMD3<Float>
        var ratio: Float
        var depth: Float
        var wristX: Float                // x na imagem ja "em pe" (0 = esquerda do usuario)
        var chirality: VNChirality
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        let tr = topRight, scale = handScale, pinchOn = self.pinchOn, fov = fovDeg
        lock.unlock()
        guard let head = head else { return }
        let tCam = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard let q = head.history.nearest(to: tCam) else { return }

        let W = Float(CVPixelBufferGetWidth(pb)), H = Float(CVPixelBufferGetHeight(pb))
        // intrinsecos do quadro NATIVO (paisagem). Se a camera nao entregar, deduz pelo campo de visao horizontal.
        var fx = (W / 2) / tan(fov * Float.pi / 360), fy = fx, cx = W / 2, cy = H / 2
        if let att = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data,
           att.count >= MemoryLayout<matrix_float3x3>.size {
            var m = matrix_float3x3()
            _ = withUnsafeMutableBytes(of: &m) { att.copyBytes(to: $0) }
            if m.columns.0.x > 50 && m.columns.1.y > 50 { fx = m.columns.0.x; fy = m.columns.1.y; cx = m.columns.2.x; cy = m.columns.2.y }
        }
        let f = (fx + fy) * 0.5

        // O sensor traseiro e "em pe" com o iPhone deitado e o TOPO a ESQUERDA. Com o topo a DIREITA o quadro esta de cabeca para baixo:
        // avisa o Vision (orientation .down) para ele ver as maos em pe.
        let req = VNDetectHumanHandPoseRequest()
        req.maximumHandCount = 2
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: tr ? .down : .up, options: [:])
        do { try handler.perform([req]) } catch { return }
        let observations = req.results ?? []

        // Vision (origem embaixo-esquerda, imagem em pe) -> pixel do quadro nativo
        func native(_ p: CGPoint) -> SIMD2<Float> {
            let x = Float(p.x), y = Float(p.y)
            return tr ? SIMD2<Float>(W * (1 - x), H * y) : SIMD2<Float>(W * x, H * (1 - y))
        }
        // pixel nativo -> direcao no referencial da CABECA (x direita, y cima, -z frente). Camera olha para a frente, como o usuario.
        let sx: Float = tr ? -1 : 1
        func ray(_ b: SIMD2<Float>) -> SIMD3<Float> {
            let nx = (b.x - cx) / fx, ny = (b.y - cy) / fy
            return SIMD3<Float>(sx * nx, -sx * ny, -1)
        }

        var dets = [Det]()
        for o in observations {
            guard let pts = try? o.recognizedPoints(.all) else { continue }
            func P(_ n: VNHumanHandPoseObservation.JointName, _ minConf: Float = 0.3) -> CGPoint? {
                guard let p = pts[n], p.confidence >= minConf else { return nil }
                return p.location
            }
            guard let wr = P(.wrist), let im = P(.indexMCP), let mm = P(.middleMCP),
                  let rm = P(.ringMCP), let lm = P(.littleMCP) else { continue }
            let bw = native(wr), bi = native(im), bm = native(mm), br = native(rm), bl = native(lm)

            // profundidade pela escala: tamanho real da palma (m) / tamanho em pixels (usa a medida menos encurtada pela perspectiva)
            let lenPx = simd_distance(bw, bm)
            let widPx = simd_distance(bi, bl) * 1.25
            let L = max(lenPx, widPx)
            if L < 8 { continue }                                         // deteccao minuscula = fantasma
            let z = min(max(f * HandSender.palmLen * scale / L, 0.10), 1.0)

            let palmPx = (bw + bi + bm + br + bl) / 5
            let palmHead = z * ray(palmPx)
            // direcao pulso -> dedo medio: no plano da imagem + a parte que falta para completar o comprimento real (aponta para a frente)
            let inPlane = z * (ray(bm) - ray(bw))
            let planeLen = sqrt(inPlane.x * inPlane.x + inPlane.y * inPlane.y)
            let real = HandSender.palmLen * scale
            let dz = sqrt(max(0, real * real - planeLen * planeLen))
            var aimHead = SIMD3<Float>(inPlane.x, inPlane.y, -dz)
            let an = simd_length(aimHead)
            aimHead = an > 1e-5 ? aimHead / an : SIMD3<Float>(0, 0, -1)

            // pinca: distancia polegar-indicador / tamanho da palma (2D)
            var ratio: Float = -1
            if let tt = P(.thumbTip, 0.2), let it = P(.indexTip, 0.2) {
                let size2 = max(lenPx, simd_distance(bi, bl)).clamped(min: 1e-3)
                ratio = simd_distance(native(tt), native(it)) / size2
            }

            let pw = HeadMath.rotate(q, SIMD3<Double>(Double(palmHead.x), Double(palmHead.y), Double(palmHead.z)))
            let aw = HeadMath.rotate(q, SIMD3<Double>(Double(aimHead.x), Double(aimHead.y), Double(aimHead.z)))
            let ox = Float(wr.x)                                          // imagem em pe: 0 = esquerda do usuario
            dets.append(Det(palm: SIMD3<Float>(Float(pw.x), Float(pw.y), Float(pw.z)),
                            aim: SIMD3<Float>(Float(aw.x), Float(aw.y), Float(aw.z)),
                            ratio: ratio, depth: z, wristX: ox, chirality: o.chirality))
        }

        let now = ProcessInfo.processInfo.systemUptime
        let tRel = Float(now - startT)
        lock.lock()
        defer { lock.unlock() }

        // uma "mao nova" alem de 0,8 m nao e do usuario (fantasma); uma que ja vinha sendo seguida pode ir mais longe
        func cont(_ d: Det) -> Int {
            var best = -1; var bd: Float = 0.25
            for h in 0..<2 where slots[h].active {
                let dd = simd_distance(d.palm, slots[h].world)
                if dd < bd { bd = dd; best = h }
            }
            return best
        }
        dets = dets.filter { $0.depth <= 0.80 || cont($0) >= 0 }
        if dets.count > 2 { dets = Array(dets.prefix(2)) }

        // identidade esquerda/direita: continuidade > posicao na imagem (2 maos) / rotulo (1 mao)
        func labelSlot(_ d: Det) -> Int {
            switch d.chirality {
            case .left: return swapVotes > 0 ? 1 : 0
            case .right: return swapVotes > 0 ? 0 : 1
            default: return d.wristX < 0.5 ? 0 : 1
            }
        }
        var assign = [Int](repeating: -1, count: dets.count)
        if dets.count == 2 {
            let ca = cont(dets[0]), cb = cont(dets[1])
            if ca >= 0 && cb >= 0 && ca != cb { assign = [ca, cb] }
            else if ca >= 0 && cb < 0 { assign = [ca, 1 - ca] }
            else if cb >= 0 && ca < 0 { assign = [1 - cb, cb] }
            else { let aLeft = dets[0].wristX <= dets[1].wristX; assign = aLeft ? [0, 1] : [1, 0] }
            // calibra o rotulo: com as maos bem separadas, a da esquerda da imagem e a esquerda
            if abs(dets[0].wristX - dets[1].wristX) > 0.2 {
                let leftDet = dets[0].wristX <= dets[1].wristX ? dets[0] : dets[1]
                if leftDet.chirality == .right { swapVotes = min(swapVotes + 1, 20) }
                else if leftDet.chirality == .left { swapVotes = max(swapVotes - 1, -20) }
            }
        } else if dets.count == 1 {
            let c = cont(dets[0])
            assign = [c >= 0 ? c : labelSlot(dets[0])]
        }

        var seen = [false, false]
        for (i, d) in dets.enumerated() {
            let h = assign[i]
            if h < 0 || h > 1 || seen[h] { continue }
            seen[h] = true
            let s = slots[h]
            if !s.active { s.reset() }
            if s.conf < 10 { s.conf += 1 }
            let dt = Float(max(now - s.lastT, 1e-3))
            s.world = s.fPos.apply(d.palm, tRel)
            var av = s.fAim.apply(d.aim, tRel)
            let an = simd_length(av)
            av = an > 1e-5 ? av / an : SIMD3<Float>(0, 0, -1)
            s.aim = av
            s.depth = d.depth
            s.lastT = now

            if d.ratio >= 0 {
                let old = s.ratio
                s.ratio = 0.7 * d.ratio + 0.3 * old
                if s.active { s.ratioVel = 0.5 * s.ratioVel + 0.5 * ((s.ratio - old) / dt) }
            }
            let rr = s.ratio
            let relMin = pinchOn + 0.06, relMax = pinchOn + 0.18
            if s.pinch {
                if rr < s.pinchMin { s.pinchMin = rr }
                let thr = min(max(s.pinchMin + 0.15, relMin), relMax)
                if rr > thr {
                    s.offCount += 1
                    let need = s.ratioVel > 0.4 ? 1 : 2                  // abrindo de proposito: solta no 1o quadro
                    if s.offCount >= need { s.pinch = false }
                } else { s.offCount = 0 }
            } else {
                s.offCount = 0
                if rr < pinchOn { s.pinch = true; s.pinchMin = rr }
            }
            s.active = true
            s.lastSeen = now
        }

        frames += 1
        if now - fpsWin >= 1 { fps = frames; frames = 0; fpsWin = now }
        if now - lastInfo > 0.5 {
            lastInfo = now
            let names = ["E", "D"]
            var parts = [String]()
            for h in 0..<2 {
                let s = slots[h]
                let live = s.active && now - s.lastSeen < 0.3
                parts.append(live ? "\(names[h]): \(Int(s.depth * 100)) cm, pinca \(String(format: "%.2f", s.ratio))\(s.pinch ? " [FECHADA]" : "")" : "\(names[h]): --")
            }
            let txt = "Maos  " + parts.joined(separator: "   ") + "   |  \(fps) fps camera, \(packets) pacotes enviados"
            DispatchQueue.main.async { self.info = txt }
        }
    }

    // ------------------------------------------------------------------ envio (60 Hz, usa a pose ATUAL da cabeca)
    private func startSendTimer() {
        let t = DispatchSource.makeTimerSource(queue: sendQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.sendPacket() }
        timer = t
        t.resume()
    }

    private struct Writer {
        var bytes = [UInt8]()
        mutating func put<T>(_ v: T) { withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) } }
    }

    private func sendPacket() {
        guard let q = head?.history.latest() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let s = fd
        var d = dest
        let sq = seq
        seq &+= 1
        let sess = session
        // frente da cabeca no plano horizontal (so o giro / yaw), igual ao PcLink.kt
        let f = HeadMath.rotate(q, SIMD3<Double>(0, 0, -1))
        let fh = SIMD2<Float>(Float(f.x), Float(f.z))
        let fn = simd_length(fh)
        if fn > 0.25 { lastFwd = fh / fn }
        let fw = lastFwd
        let right = SIMD2<Float>(-fw.y, fw.x)             // frente (0,-1) -> direita (1,0)
        let back = SIMD2<Float>(-fw.x, -fw.y)

        var sides = [(flags: UInt8, pos: SIMD3<Float>, aim: SIMD3<Float>, ratio: Float)]()
        for h in 0..<2 {
            let sl = slots[h]
            let hold = (sl.pinch || sl.ratio < 0.55) ? 0.45 : 0.20     // mao fechada some do detector por instantes: segura a pose
            if sl.active && now - sl.lastSeen > hold { sl.reset() }
            if sl.active && sl.conf >= 2 {
                var fl: UInt8 = 1
                if sl.pinch { fl |= 2 }
                let w = sl.world, a = sl.aim
                let pos = SIMD3<Float>(w.x * right.x + w.z * right.y, w.y, w.x * back.x + w.z * back.y)
                let aim = SIMD3<Float>(a.x * right.x + a.z * right.y, a.y, a.x * back.x + a.z * back.y)
                sides.append((fl, pos, aim, sl.ratio))
            } else {
                sides.append((0, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 0), 1))
            }
        }
        if s >= 0 { packets += 1 }
        lock.unlock()
        guard s >= 0 else { return }

        var w = Writer()
        w.bytes.reserveCapacity(92)
        w.put(HandSender.magic)
        w.put(deviceId)
        w.put(sess)
        w.put(sq)
        w.put(UInt64(max(0, now) * 1_000_000))
        w.put(UInt16(3))                                   // KBT_HAND_F_POS | KBT_HAND_F_PINCH
        w.put(UInt16(0))
        for sd in sides {                                  // [0] = esquerda, [1] = direita
            w.put(sd.flags); w.put(UInt8(0)); w.put(UInt8(0)); w.put(UInt8(0))
            w.put(sd.pos.x); w.put(sd.pos.y); w.put(sd.pos.z)
            w.put(sd.aim.x); w.put(sd.aim.y); w.put(sd.aim.z)
            w.put(sd.ratio)
        }
        let bytes = w.bytes
        _ = bytes.withUnsafeBytes { buf in
            withUnsafePointer(to: &d) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(s, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

private extension Float {
    func clamped(min lo: Float) -> Float { self < lo ? lo : self }
}
