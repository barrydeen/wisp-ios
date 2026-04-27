import SwiftUI
import CoreImage.CIFilterBuiltins

/// SwiftUI view that renders a string as a QR code via Core Image.
/// `correctionLevel` is the Core Image error-correction code: "L" (~7%), "M" (~15%),
/// "Q" (~25%), "H" (~30%). Use "H" when overlaying a center logo so the symbol still
/// scans through the occlusion.
struct QRCodeImage: View {
    let payload: String
    var sideLength: CGFloat = 220
    var correctionLevel: String = "M"

    var body: some View {
        if let image = makeImage() {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .frame(width: sideLength, height: sideLength)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.tertiary)
                .frame(width: sideLength, height: sideLength)
                .overlay(Text("QR error").font(.caption).foregroundStyle(.secondary))
        }
    }

    private func makeImage() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correctionLevel
        guard let ciImage = filter.outputImage else { return nil }
        let scale = sideLength * UIScreen.main.scale / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
