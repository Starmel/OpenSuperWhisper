import SwiftUI

struct ToastHostView: View {
    @EnvironmentObject var toast: ToastManager

    var body: some View {
        VStack {
            if let item = toast.current {
                BlurToast(item: item) {
                    toast.current = nil
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 12)
                .padding(.horizontal, 12)
            }
            Spacer().frame(height: 0)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toast.current?.id)
    }
}
