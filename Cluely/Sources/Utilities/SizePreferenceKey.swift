import SwiftUI

struct SizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension View {
    func readSize(onChange: @escaping (CGSize) -> Void) -> some View {
        overlay(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        onChange(geometry.size)
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        onChange(newSize)
                    }
            }
        )
    }
}
