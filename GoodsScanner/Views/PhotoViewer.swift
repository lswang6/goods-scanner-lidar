import SwiftUI

/// SPEC §11 D3: what to show in `PhotoViewer`. Present with `.fullScreenCover(item:)`.
struct PhotoSelection: Identifiable {
    let id = UUID()
    let files: [String]
    let start: Int
}

/// Full-screen paged photo viewer: swipe between pages, pinch / double-tap zoom, pan when zoomed, share.
struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let files: [String]
    @State private var index: Int

    init(_ selection: PhotoSelection) {
        files = selection.files
        _index = State(initialValue: min(max(selection.start, 0), max(selection.files.count - 1, 0)))
    }

    var body: some View {
        TabView(selection: $index) {
            ForEach(files.indices, id: \.self) { i in
                ZoomablePhoto(name: files[i], isCurrent: i == index).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black)
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Text("\(index + 1) / \(files.count)").font(.num(.headline))
                Spacer()
                if files.indices.contains(index) {
                    ShareLink(item: PhotoStore.url(files[index])) {
                        Image(systemName: "square.and.arrow.up").accessibilityLabel("Share")
                    }
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.black.opacity(0.4))
        }
        .statusBarHidden()
    }
}

private struct ZoomablePhoto: View {
    let name: String
    let isCurrent: Bool
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    private static let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(scale).offset(offset)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if scale > 1 { reset() } else { scale = 2.5; lastScale = 2.5 }
                }
            }
            .gesture(MagnifyGesture()
                .onChanged { scale = min(max(lastScale * $0.magnification, 1), Self.maxScale); offset = clamp(offset, geo.size) }
                .onEnded { _ in
                    lastScale = scale
                    if scale <= 1 { withAnimation { reset() } } else { offset = clamp(offset, geo.size); lastOffset = offset }
                })
            // Only claim drags while zoomed, so the TabView can page at 1x.
            .gesture(DragGesture()
                .onChanged { offset = clamp(CGSize(width: lastOffset.width + $0.translation.width,
                                                   height: lastOffset.height + $0.translation.height), geo.size) }
                .onEnded { _ in lastOffset = offset },
                     including: scale > 1 ? .all : .subviews)
        }
        .onChange(of: isCurrent) { _, current in if !current { reset() } }
        .task(id: name) {
            // Full-res, loaded per page as TabView builds it; decode off the main thread.
            let n = name
            image = await Task.detached { await PhotoStore.image(n)?.byPreparingForDisplay() }.value
        }
    }

    private func reset() { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }

    /// Keep the zoomed image covering the screen: pan at most half the overflow on each axis.
    private func clamp(_ o: CGSize, _ box: CGSize) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = min(box.width / image.size.width, box.height / image.size.height)
        let mx = max(0, (image.size.width * fit * scale - box.width) / 2)
        let my = max(0, (image.size.height * fit * scale - box.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }
}
