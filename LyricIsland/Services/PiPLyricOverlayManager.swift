import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import UIKit

@MainActor
final class PiPLyricOverlayManager: NSObject, ObservableObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var isPiPActive: Bool = false
    @Published private(set) var isPiPPossible: Bool = false
    @Published private(set) var isPiPSupported: Bool = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var lastErrorMessage: String?

    var onTogglePlayTapped: (() -> Void)?
    var onSkipBackwardTapped: (() -> Void)?
    var onSkipForwardTapped: (() -> Void)?

    let displayLayer = AVSampleBufferDisplayLayer()

    private var pipController: AVPictureInPictureController?
    private var refreshTimer: Timer?
    private var startTime = CACurrentMediaTime()

    private var currentTrackTitle: String = "詞島 LyricIsland"
    private var currentArtist: String = ""
    private var currentSourceLabel: String = "待機"
    private var currentLine: String = "靈動歌詞已就緒"
    private var secondaryLine: String = ""
    private var currentArtwork: UIImage?
    private var accentColor: UIColor = UIColor(red: 1.0, green: 0.231, blue: 0.188, alpha: 1.0)
    private var isPlaying: Bool = false
    private var elapsed: TimeInterval = 0
    private var duration: TimeInterval = 1
    private var hudBanner: String?
    private var hudBannerClearTask: Task<Void, Never>?

    private var lastFrameFingerprint: String = ""
    private var cachedPixelBuffer: CVPixelBuffer?

    override init() {
        super.init()
        setupDisplayLayer()
    }

    private func setupDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor

        if AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.requiresLinearPlayback = false
            pipController = controller
            isPiPPossible = controller.isPictureInPicturePossible
        }
    }

    func updateContent(
        trackTitle: String,
        artist: String,
        sourceLabel: String,
        currentLine: String,
        secondaryLine: String,
        artwork: UIImage?,
        accentRGB: (red: Double, green: Double, blue: Double),
        isPlaying: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) {
        self.currentTrackTitle = trackTitle
        self.currentArtist = artist
        self.currentSourceLabel = sourceLabel
        self.currentLine = currentLine
        self.secondaryLine = secondaryLine
        self.currentArtwork = artwork
        self.accentColor = UIColor(
            red: accentRGB.red,
            green: accentRGB.green,
            blue: accentRGB.blue,
            alpha: 1.0
        )
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.duration = max(duration, 1)

        pushCurrentFrame(forceRedraw: false)
    }

    func showTransientBadge(_ text: String) {
        hudBanner = text
        hudBannerClearTask?.cancel()
        hudBannerClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.hudBanner = nil
            self.pushCurrentFrame(forceRedraw: true)
        }
        pushCurrentFrame(forceRedraw: true)
    }

    func startPiP(ensureAudioMix: Bool = true) {
        guard let pipController else {
            lastErrorMessage = "此裝置不支援畫中畫懸浮歌詞"
            return
        }
        if pipController.isPictureInPictureActive { return }

        if ensureAudioMix {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                try session.setActive(true)
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }

        pushCurrentFrame(forceRedraw: true)
        startHeartbeatIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, let controller = self.pipController else { return }
            self.isPiPPossible = controller.isPictureInPicturePossible
            if !controller.isPictureInPictureActive {
                controller.startPictureInPicture()
            }
        }
    }

    func stopPiP() {
        guard let pipController, pipController.isPictureInPictureActive else { return }
        pipController.stopPictureInPicture()
    }

    func togglePiP() {
        if isPiPActive {
            stopPiP()
        } else {
            startPiP()
        }
    }

    // MARK: - Heartbeat & Rendering

    private func startHeartbeatIfNeeded() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] t in
            guard let self else {
                t.invalidate()
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isPiPActive {
                    self.pushCurrentFrame(forceRedraw: false)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopHeartbeatIfIdle() {
        if !isPiPActive {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    func pushCurrentFrame(forceRedraw: Bool = false) {
        let bucketProgress = Int((elapsed / max(duration, 1)) * 200)
        let artHash = currentArtwork.map { ObjectIdentifier($0).hashValue } ?? 0
        let fingerprint = "\(currentTrackTitle)|\(currentArtist)|\(currentSourceLabel)|\(currentLine)|\(secondaryLine)|\(isPlaying)|\(bucketProgress)|\(Int(elapsed))|\(hudBanner ?? "")|\(artHash)"

        let pixelBuffer: CVPixelBuffer?
        if forceRedraw || cachedPixelBuffer == nil || fingerprint != lastFrameFingerprint {
            let image = renderCapsuleImage()
            pixelBuffer = makePixelBuffer(from: image)
            if let pixelBuffer {
                cachedPixelBuffer = pixelBuffer
                lastFrameFingerprint = fingerprint
            }
        } else {
            pixelBuffer = cachedPixelBuffer
        }

        guard let buffer = pixelBuffer,
              let sampleBuffer = makeSampleBuffer(from: buffer) else { return }

        if displayLayer.sampleBufferRenderer.status == .failed {
            displayLayer.sampleBufferRenderer.flush()
        }
        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)

        if let pipController {
            isPiPPossible = pipController.isPictureInPicturePossible
        }
    }

    private func renderCapsuleImage() -> UIImage {
        let size = CGSize(width: 880, height: 320)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext

            // Pure OLED Black Background
            UIColor(red: 0.02, green: 0.02, blue: 0.028, alpha: 1.0).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // Subtle ambient top accent wash
            var r: CGFloat = 1, g: CGFloat = 0.23, b: CGFloat = 0.19, a: CGFloat = 1
            accentColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            let gradientColors = [
                UIColor(red: r, green: g, blue: b, alpha: 0.16).cgColor,
                UIColor.clear.cgColor
            ] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gradientColors, locations: [0, 1]) {
                cg.drawRadialGradient(
                    grad,
                    startCenter: CGPoint(x: 110, y: 40),
                    startRadius: 10,
                    endCenter: CGPoint(x: 240, y: 120),
                    endRadius: 520,
                    options: []
                )
            }

            // Inner hairline card frame
            let cardRect = CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20)
            let framePath = UIBezierPath(roundedRect: cardRect, cornerRadius: 34)
            UIColor.white.withAlphaComponent(0.11).setStroke()
            framePath.lineWidth = 1.5
            framePath.stroke()

            // Header: Album Art + Track + Source + Monospace Clock
            let artRect = CGRect(x: 34, y: 30, width: 54, height: 54)
            cg.saveGState()
            UIBezierPath(roundedRect: artRect, cornerRadius: 12).addClip()
            if let artwork = currentArtwork {
                artwork.draw(in: artRect)
            } else {
                accentColor.withAlphaComponent(0.24).setFill()
                cg.fill(artRect)
                let noteAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: accentColor
                ]
                NSString(string: "♪").draw(at: CGPoint(x: artRect.midX - 8, y: artRect.midY - 14), withAttributes: noteAttr)
            }
            cg.restoreGState()

            let titleAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor(white: 0.96, alpha: 1.0)
            ]
            let subText = currentArtist.isEmpty ? currentSourceLabel : "\(currentArtist) · \(currentSourceLabel)"
            let subAttr: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 17, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.56)
            ]

            NSString(string: currentTrackTitle).draw(
                in: CGRect(x: 104, y: 30, width: 520, height: 28),
                withAttributes: titleAttr
            )
            NSString(string: subText).draw(
                in: CGRect(x: 104, y: 59, width: 520, height: 24),
                withAttributes: subAttr
            )

            // Top Right Clock / Transient Badge
            let rightStyle = NSMutableParagraphStyle()
            rightStyle.alignment = .right
            let badgeText = hudBanner ?? "\(LRCParser.formatTime(elapsed)) / \(LRCParser.formatTime(duration))"
            let badgeColor = hudBanner != nil ? accentColor : UIColor.white.withAlphaComponent(0.62)
            NSString(string: badgeText).draw(
                in: CGRect(x: 630, y: 40, width: 214, height: 28),
                withAttributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold),
                    .foregroundColor: badgeColor,
                    .paragraphStyle: rightStyle
                ]
            )

            // Active Accent Bar + Primary Lyric + Secondary Line
            let barRect = CGRect(x: 36, y: 112, width: 5, height: secondaryLine.isEmpty ? 96 : 128)
            accentColor.setFill()
            UIBezierPath(roundedRect: barRect, cornerRadius: 2.5).fill()

            let primaryFontSize: CGFloat = currentLine.count > 22 ? 32 : (currentLine.count > 14 ? 37 : 42)
            let lyricPara = NSMutableParagraphStyle()
            lyricPara.lineBreakMode = .byTruncatingTail
            lyricPara.lineSpacing = 4

            NSString(string: currentLine).draw(
                in: CGRect(x: 56, y: 110, width: 788, height: 108),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: primaryFontSize, weight: .bold),
                    .foregroundColor: UIColor(white: 0.97, alpha: 1.0),
                    .paragraphStyle: lyricPara
                ]
            )

            if !secondaryLine.isEmpty {
                let secPara = NSMutableParagraphStyle()
                secPara.lineBreakMode = .byTruncatingTail
                NSString(string: secondaryLine).draw(
                    in: CGRect(x: 56, y: 222, width: 788, height: 34),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 22, weight: .medium),
                        .foregroundColor: UIColor.white.withAlphaComponent(0.56),
                        .paragraphStyle: secPara
                    ]
                )
            }

            // Bottom Sleek Progress Bar
            let trackRect = CGRect(x: 34, y: 276, width: size.width - 68, height: 6)
            UIColor.white.withAlphaComponent(0.14).setFill()
            UIBezierPath(roundedRect: trackRect, cornerRadius: 3).fill()

            let fraction = min(max(elapsed / max(duration, 1), 0), 1)
            let fillWidth = max(10, trackRect.width * fraction)
            let fillRect = CGRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: 6)
            accentColor.setFill()
            UIBezierPath(roundedRect: fillRect, cornerRadius: 3).fill()
        }
    }

    // MARK: - AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
            self.startHeartbeatIfNeeded()
            self.pushCurrentFrame(forceRedraw: true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
            self.stopHeartbeatIfIdle()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isPiPActive = false
            self.lastErrorMessage = "懸浮窗啟動失敗：\(error.localizedDescription)"
            self.stopHeartbeatIfIdle()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.onTogglePlayTapped?()
            self?.pushCurrentFrame(forceRedraw: true)
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        Task { @MainActor in
            self.pushCurrentFrame(forceRedraw: true)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let forward = skipInterval.seconds >= 0
        Task { @MainActor [weak self] in
            if forward {
                self?.onSkipForwardTapped?()
            } else {
                self?.onSkipBackwardTapped?()
            }
        }
        completionHandler()
    }

    // MARK: - PixelBuffer & SampleBuffer Conversion

    private func makePixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard fmtStatus == noErr, let videoFormat = formatDesc else { return nil }

        let elapsedTime = max(0.0, CACurrentMediaTime() - startTime)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: CMTime(seconds: elapsedTime, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: videoFormat,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let buffer = sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0,
           let rawValue = CFArrayGetValueAtIndex(attachments, 0) {
            let dict = unsafeBitCast(rawValue, to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return buffer
    }
}

struct PiPBufferHostView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> PiPLayerContainerView {
        let view = PiPLayerContainerView()
        view.attach(layer: displayLayer)
        return view
    }

    func updateUIView(_ uiView: PiPLayerContainerView, context: Context) {
        uiView.attach(layer: displayLayer)
    }
}

final class PiPLayerContainerView: UIView {
    private weak var attachedLayer: AVSampleBufferDisplayLayer?

    func attach(layer: AVSampleBufferDisplayLayer) {
        if attachedLayer !== layer {
            attachedLayer?.removeFromSuperlayer()
            layer.frame = bounds
            self.layer.addSublayer(layer)
            attachedLayer = layer
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachedLayer?.frame = bounds
    }
}
