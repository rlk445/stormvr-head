import SwiftUI

/// Tela cheia com o video (os 2 olhos lado a lado ja vem prontos do driver).
struct VideoScreen: View {
    @ObservedObject var video: VideoReceiver
    var close: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = video.image {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
            } else {
                Text(video.status).foregroundColor(.white).padding()
            }
            VStack {
                HStack {
                    Spacer()
                    Text("\(video.fps) fps").font(.caption).foregroundColor(.gray)
                    Button("Fechar", action: close).padding(8)
                }
                Spacer()
            }
        }
        .statusBar(hidden: true)
    }
}
