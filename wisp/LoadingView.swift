import SwiftUI

struct LoadingView: View {
    var onReady: () -> Void
    var delay: Int = 800

    @State private var rotation: Double = 0
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("WispLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)

            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.wispPrimary, lineWidth: 3)
                .frame(width: 32, height: 32)
                .rotationEffect(.degrees(rotation))

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.wispBackground)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(delay))
            onReady()
        }
    }
}
