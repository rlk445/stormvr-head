import Foundation
import AVFoundation
import CoreLocation

/// O iOS suspende apps em segundo plano. Enquanto o Moonlight esta na tela, este app precisa continuar
/// lendo o giroscopio. Usamos (1) um audio inaudivel que mistura com o som do Moonlight e
/// (2) localizacao de baixa precisao em segundo plano. Os dois juntos sao mais confiaveis que um so.
final class KeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = KeepAlive()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var audioReady = false
    private let loc = CLLocationManager()
    private var active = false

    func start() {
        active = true
        startAudio()
        DispatchQueue.main.async {
            self.loc.delegate = self
            self.loc.desiredAccuracy = kCLLocationAccuracyThreeKilometers
            self.loc.pausesLocationUpdatesAutomatically = false
            self.loc.allowsBackgroundLocationUpdates = true
            self.loc.requestWhenInUseAuthorization()
            self.loc.startUpdatingLocation()
        }
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(interruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    func stop() {
        active = false
        NotificationCenter.default.removeObserver(self)
        if player.isPlaying { player.stop() }
        if engine.isRunning { engine.stop() }
        DispatchQueue.main.async { self.loc.stopUpdatingLocation() }
    }

    private func startAudio() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
            let rate = 44100.0
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let frames = AVAudioFrameCount(rate)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
            buf.frameLength = frames
            let p = buf.floatChannelData![0]
            for i in 0..<Int(frames) { p[i] = 0.00003 * sinf(Float(i) * 0.05) }   // praticamente mudo
            if !audioReady {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: fmt)
                audioReady = true
            }
            player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
            if !engine.isRunning { try engine.start() }
            player.play()
        } catch {
            // sem audio: ainda ha a localizacao como plano B
        }
    }

    @objc private func interruption(_ n: Notification) {
        guard active,
              let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: v) == .ended else { return }
        startAudio()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
