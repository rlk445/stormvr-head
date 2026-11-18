import SwiftUI

@main
struct StormVRHeadApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var sender = HeadSender()
    @StateObject private var video = VideoReceiver()
    @State private var showVideo = false
    @AppStorage("host") private var host = ""
    @AppStorage("hz") private var hz = 100
    @AppStorage("topRight") private var topRight = true

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
                    set: { topRight = $0; sender.setTopRight($0) }
                )) {
                    Text("Topo à DIREITA").tag(true)
                    Text("Topo à ESQUERDA").tag(false)
                }.pickerStyle(.segmented)

                Text("Taxa de envio").font(.subheadline)
                Picker("", selection: $hz) {
                    Text("60 Hz").tag(60)
                    Text("100 Hz").tag(100)
                }.pickerStyle(.segmented)

                Button(action: toggle) {
                    Text(sender.running ? "PARAR" : "INICIAR")
                        .bold().frame(maxWidth: .infinity).padding()
                        .background(sender.running ? Color.red : Color.blue)
                        .foregroundColor(.white).cornerRadius(10)
                }

                Button(action: {
                    if !sender.running { toggle() }
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
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            sender.start(host: host, hz: hz, topRight: topRight)
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
}
