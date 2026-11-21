import AppKit
import AVKit
import ImageIO
import PDFKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Shows a file's contents: text, image, audio/video, PDF, or a Quick Look thumbnail.
/// Used by Find Duplicates to show two copies side by side.
struct ContentPreview: View {
    let path: String
    /// Player for audio/video files (owned by the caller so two previews can play together).
    var player: AVPlayer?

    @State private var loaded: PreviewContent?

    var body: some View {
        ZStack {
            switch loaded {
            case nil:
                ProgressView().controlSize(.small)
            case .media:
                if let player {
                    PlayerView(player: player)
                } else {
                    PreviewMessage(path: path, text: "No player available")
                }
            case .pdf(let url):
                PDFPreview(url: url)
            case .image(let image, let pixels):
                VStack(spacing: 6) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text("\(Int(pixels.width)) × \(Int(pixels.height)) pixels")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
            case .text(let text, let truncated):
                VStack(spacing: 0) {
                    ReadOnlyTextView(text: text)
                    if truncated {
                        Divider()
                        Text("Showing the first \(Format.bytes(Int64(PreviewLoader.textLimit)))")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(4)
                    }
                }
            case .thumbnail(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 360)
                    .padding()
            case .unavailable(let message):
                PreviewMessage(path: path, text: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: path) {
            loaded = nil
            loaded = await PreviewLoader.load(path: path)
        }
    }
}

enum PreviewContent {
    case media
    case pdf(URL)
    case image(NSImage, CGSize)
    case text(String, truncated: Bool)
    case thumbnail(NSImage)
    case unavailable(String)
}

private struct PreviewMessage: View {
    let path: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable().frame(width: 96, height: 96)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// Decides how to preview a file and loads it off the main thread.
enum PreviewLoader {
    static let textLimit = 512 * 1024
    static let imageMaxPixels = 2048

    enum Kind: Equatable { case media, pdf, image, text, other }

    /// Kind from the file name alone; `.other` files may still be sniffed as text.
    static func kind(forPath path: String) -> Kind {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .audiovisualContent) { return .media }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text) { return .text }
        return .other
    }

    static func isMedia(_ path: String) -> Bool { kind(forPath: path) == .media }

    static func load(path: String) async -> PreviewContent {
        switch kind(forPath: path) {
        case .media:
            return .media
        case .pdf:
            return .pdf(URL(fileURLWithPath: path))
        case .image:
            if let (image, size) = await Task.detached(priority: .userInitiated, operation: { image(at: path) }).value {
                return .image(image, size)
            }
            return await thumbnailOrMessage(path)
        case .text:
            if let (text, truncated) = await Task.detached(priority: .userInitiated, operation: { readText(path, sniff: false) }).value {
                return .text(text, truncated: truncated)
            }
            return await thumbnailOrMessage(path)
        case .other:
            if let (text, truncated) = await Task.detached(priority: .userInitiated, operation: { readText(path, sniff: true) }).value {
                return .text(text, truncated: truncated)
            }
            return await thumbnailOrMessage(path)
        }
    }

    private static func thumbnailOrMessage(_ path: String) async -> PreviewContent {
        if let thumb = await quickLookThumbnail(path) { return .thumbnail(thumb) }
        return .unavailable("No preview for this kind of file")
    }

    /// Downsampled image (never decodes a giant image at full size), with its real pixel size.
    static func image(at path: String) -> (NSImage, CGSize)? {
        guard let data = readPrefix(path, limit: nil) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: imageMaxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return (image, CGSize(width: width > 0 ? width : Double(cg.width), height: height > 0 ? height : Double(cg.height)))
    }

    /// Up to `textLimit` bytes decoded as text. With `sniff`, only files that look like text
    /// (no NUL bytes in the first 8 KB and valid UTF-8, or a UTF-16 byte-order mark) qualify.
    static func readText(_ path: String, sniff: Bool) -> (String, Bool)? {
        guard let data = readPrefix(path, limit: textLimit + 1) else { return nil }
        let truncated = data.count > textLimit
        let bytes = truncated ? data.prefix(textLimit) : data[...]
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let little = bytes.starts(with: [0xFF, 0xFE])
            var even = Data(bytes.dropFirst(2))
            if even.count % 2 == 1 { even.removeLast() }
            if let s = String(data: even, encoding: little ? .utf16LittleEndian : .utf16BigEndian) { return (s, truncated) }
            return nil
        }
        if sniff {
            let head = bytes.prefix(8192)
            if head.contains(0) { return nil }
            // Allow a multi-byte character cut off at the end of the sample.
            var sample = Data(head)
            var valid = String(data: sample, encoding: .utf8) != nil
            var trimmed = 0
            while !valid && trimmed < 3 && !sample.isEmpty && head.count == 8192 {
                sample.removeLast(); trimmed += 1
                valid = String(data: sample, encoding: .utf8) != nil
            }
            if !valid { return nil }
        }
        return (String(decoding: bytes, as: UTF8.self), truncated)
    }

    /// Reads a regular file safely: never follows a symlink, never blocks on a FIFO, never reads
    /// a cloud placeholder (that would download it). `limit` nil = whole file (capped at 256 MB).
    static func readPrefix(_ path: String, limit: Int?) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_flags & DuplicateFinder.datalessFlag == 0 else { return nil }
        let cap = limit ?? 256 * 1024 * 1024
        let want = Int(min(Int64(cap), Int64(st.st_size)))
        var data = Data(count: want)
        var got = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            while got < want {
                let n = read(fd, raw.baseAddress! + got, want - got)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { break }
                got += n
            }
            return true
        }
        guard ok else { return nil }
        data.count = got
        return data
    }

    @MainActor
    static func quickLookThumbnail(_ path: String) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                                   size: CGSize(width: 512, height: 512),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
    }
}

/// Read-only, selectable, monospaced text (NSTextView stays fast with hundreds of KB).
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.importsGraphics = false
            tv.usesFindBar = true
            tv.isIncrementalSearchingEnabled = true
            tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            tv.textColor = .labelColor
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.isAutomaticLinkDetectionEnabled = false
            tv.isAutomaticDataDetectionEnabled = false
            tv.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
        tv.scrollToBeginningOfDocument(nil)
    }
}

/// AppKit's player view (native macOS transport controls; doesn't autoplay).
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

/// Audio/video players for the panes of one comparison, so "Play Both" can start them together.
@MainActor
final class PreviewPlayers: ObservableObject {
    private var players: [String: AVPlayer] = [:]

    func player(for path: String) -> AVPlayer? {
        guard PreviewLoader.isMedia(path) else { return nil }
        if let p = players[path] { return p }
        let p = AVPlayer(url: URL(fileURLWithPath: path))
        p.actionAtItemEnd = .pause
        players[path] = p
        return p
    }

    /// Keep only the players for the files on screen.
    func keep(_ paths: [String]) {
        for (path, p) in players where !paths.contains(path) {
            p.pause()
            players[path] = nil
        }
    }

    func playTogether(_ paths: [String]) {
        let list = paths.compactMap { player(for: $0) }
        for p in list { p.pause(); p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) }
        for p in list { p.play() }
    }

    func pauseAll() { players.values.forEach { $0.pause() } }
}
