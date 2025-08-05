import SwiftUI
import AppKit

struct BlurToast: View {
    let item: ToastItem
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.style == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(item.style == .error ? .red : .blue)
                .imageScale(.large)

            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)

            Spacer(minLength: 8)

            if let actionTitle = item.actionTitle, let action = item.action {
                Button(actionTitle) { action() }
                    .buttonStyle(.bordered)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        }
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.state = .active
        v.material = material
        v.blendingMode = blendingMode
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
