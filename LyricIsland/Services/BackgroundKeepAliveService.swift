import AVFoundation
import Foundation

@MainActor
final class BackgroundKeepAliveService {
    private var silentPlayer: AVAudioPlayer?
    private var isRunning = false
    private var interruptionObserver: NSObjectProtocol?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let info = notification.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            if type == .ended {
                Task { @MainActor in
                    if self.isRunning {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.silentPlayer?.play()
                    }
                }
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func setKeepAliveActive(_ active: Bool) {
        if active {
            startSilentLoopIfNeeded()
        } else {
            stopSilentLoop()
        }
    }

    private func startSilentLoopIfNeeded() {
        if isRunning, silentPlayer?.isPlaying == true { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if silentPlayer == nil {
                let wavData = Self.makeSilentWavData(durationSeconds: 1.0, sampleRate: 8000)
                let player = try AVAudioPlayer(data: wavData)
                player.numberOfLoops = -1
                player.volume = 0.0
                player.prepareToPlay()
                silentPlayer = player
            }

            silentPlayer?.play()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    private func stopSilentLoop() {
        isRunning = false
        silentPlayer?.stop()
    }

    private static func makeSilentWavData(durationSeconds: Double, sampleRate: UInt32) -> Data {
        let numSamples = Int(Double(sampleRate) * durationSeconds)
        let dataSize = UInt32(numSamples * 2) // 16-bit mono
        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        func appendASCII(_ str: String) {
            data.append(contentsOf: str.utf8)
        }
        func appendLE<T: FixedWidthInteger>(_ val: T) {
            var v = val.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendLE(UInt32(36) + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(UInt16(1)) // Mono
        appendLE(sampleRate)
        appendLE(sampleRate * 2)
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        appendASCII("data")
        appendLE(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
