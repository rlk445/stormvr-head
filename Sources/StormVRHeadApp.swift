import SwiftUI

@main
struct StormVRHeadApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var sender = HeadSender()
    @StateObject private var video = VideoReceiver()
    @StateObject private var hands = HandSender()
    @State private var showVideo = false
    @AppStorage("host") private var host = ""
    @AppStorage("hz") private var hz = 100
    @AppStorage("topRight") private var topRight = true
    @AppStorage("useHands") private var useHands = true
    @AppStorage("handScale") private var handScale = 1.0
    @AppStorage("pinchOn") private var pinchOn = 0.40

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("StormVR Head").font(.largeTitle).bold()
                Text("Envia a posicao da cabeca do iPhone para o driver StormVR no PC. Depois abra o Moonlight.")
                    .font(.footnote).foregroundColor(.secondary)

                Text("IP do PC (ipconfig > Endereco IPv4)").font(.subheadline)
                TextField("ex.: 192.168.0.10", text: $host)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)

                Text("Topo do iPhone, com ele deitado no oculos").font(.subheadline)
                Picker("", selection: Binding(
                    get: { topRight },
                    set: { topRight = $0; sender.setTopRight($0); hands.setTopRight($0) }
                )) {
                    Text("Topo à DIREITA").tag(true)
                    Text("Topo à ESQUERDA").tag(false)
                }.pickerStyle(.segmented)

                Text("Taxa de envio").font(.subheadline)
                Picker("", selection: $hz) {
                    Text("60 Hz").tag(60)
                    Text("100 Hz").tag(100)
                }.pickerStyle(.segmented)

                Toggle("Rastrear MAOS com a camera (estilo Quest)", isOn: $useHands)
                    .font(.subheadline)
                if useHands {
                    Text("Tamanho da mao: \(Int(handScale * 100))%  (muda a distancia estimada das maos)").font(.footnote)
                    Slider(value: Binding(get: { handScale }, set: { handScale = $0; hands.setHandScale(Float($0)) }), in: 0.6...1.6)
                    Text("Sensibilidade da pinca: \(String(format: "%.2f", pinchOn))  (maior = fecha a pinca mais facil)").font(.footnote)
                    Slider(value: Binding(get: { pinchOn }, set: { pinchOn = $0; hands.setPinchOn(Float($0)) }), in: 0.25...0.60)
                    Text("A camera so funciona com este app NA TELA. Use o botao verde (video dentro do app); com o Moonlight na frente o iOS desliga a camera.")
                        .font(.footnote).foregroundColor(.orange)
                }

                Button(action: toggle) {
                    Text(sender.running ? "PARAR" : "INICIAR")
                        .bold().frame(maxWidth: .infinity).padding()
                        .background(sender.running ? Color.red : Color.blue)
                        .foregroundColor(.white).cornerRadius(10)
                }

                Button(action: {
                    if !sender.running { toggle() }
                    else if useHands && !hands.running {
                        hands.start(host: host, head: sender, topRight: topRight, handScale: Float(handScale), pinchOn: Float(pinchOn))
                    }
                    video.start(host: host)
                    showVideo = true
                }) {
                    Text("Abrir VIDEO (stormvr_video.py no PC)")
                        .bold().frame(maxWidth: .infinity).padding()
                        .background(Color.green).foregroundColor(.white).cornerRadius(10)
                }

                Button(action: { sender.recenter() }) {
                    Text("Recentralizar (olhe para a frente e toque)")
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.gray.opacity(0.25)).cornerRadius(10)
                }.disabled(!sender.running)

                Group {
                    Text(sender.status).font(.callout)
                    if useHands {
                        Text("Maos: \(hands.status)").font(.callout)
                        if !hands.info.isEmpty { Text(hands.info).font(.system(.footnote, design: .monospaced)) }
                    }
                    Text("Pacotes/s: \(sender.packetsPerSec)")
                    Text(String(format: "Yaw %.0f°   Pitch %.0f°   Roll %.0f°", sender.yaw, sender.pitch, sender.roll))
                        .font(.system(.body, design: .monospaced))
                    Text("Teste: olhar para CIMA = Pitch positivo. Virar para a ESQUERDA = Yaw positivo. Se estiver ao contrario, troque o lado do topo do iPhone.")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Text("Mantenha este app ABERTO ao iniciar, depois troque para o Moonlight. Ele continua enviando em segundo plano.")
                    .font(.footnote).foregroundColor(.secondary)
            }.padding()
        }
        .fullScreenCover(isPresented: $showVideo) {
            VideoScreen(video: video) { video.stop(); showVideo = false }
        }
    }

    private func toggle() {
        if sender.running {
            sender.stop()
            hands.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            sender.start(host: host, hz: hz, topRight: topRight)
            if useHands && sender.running {
                hands.start(host: host, head: sender, topRight: topRight, handScale: Float(handScale), pinchOn: Float(pinchOn))
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
}
