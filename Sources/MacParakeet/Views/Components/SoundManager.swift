import AVFoundation

/// Audio feedback system for MacParakeet.
/// Preloads sounds for zero-latency playback. Respects macOS sound settings.
final class SoundManager {
    static let shared = SoundManager()

    private var players: [AppSound: AVAudioPlayer] = [:]
    private let volume: Float = 0.3

    private init() {
        preloadSounds()
    }

    /// Play a sound effect.
    func play(_ sound: AppSound) {
        // Respect macOS "Play sound effects" setting
        guard UserDefaults.standard.bool(forKey: "com.apple.sound.uiaudio.enabled") != false else { return }

        guard let player = players[sound] else { return }
        player.currentTime = 0
        player.play()
    }

    private func preloadSounds() {
        for sound in AppSound.allCases {
            guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "aif")
                    ?? Bundle.main.url(forResource: sound.rawValue, withExtension: "wav") else {
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = volume
                player.prepareToPlay()
                players[sound] = player
            } catch {
                // Sound assets not yet bundled — this is expected until assets are created
            }
        }
    }
}

/// Named sound effects for MacParakeet.
/// Assets will be bundled as .aif files in the app resources.
enum AppSound: String, CaseIterable {
    case recordStart = "record_start"
    case recordStop = "record_stop"
    case transcriptionComplete = "transcription_complete"
    case fileDropped = "file_dropped"
    case errorSoft = "error_soft"
    case copyClick = "copy_click"
}
