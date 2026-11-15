import Foundation
import AVFoundation

/// Detects the wake word (“Hey Claude” or “Claudi”) in the speech recognition text
/// and returns the rest of the sentence as the command.
///
/// “Claude” alone is deliberately not enough – otherwise every conversation *about* Claude would trigger it.
/// The list contains typical mishearings by the speech recognizer, including German ones (“Hey Cloud”, “Klaudi”).
enum WakeWord {
    struct Match: Equatable {
        /// The actual command starts here in the original text
        let commandStart: String.Index
    }

    /// Word sequences (already normalized: lowercase, no accents)
    static let phrases: [[String]] = [
        ["hey", "claude"], ["hey", "cloud"], ["hey", "claud"], ["hey", "klaud"], ["hey", "clod"], ["hey", "klod"],
        ["hey", "claudi"], ["hey", "klaudi"],
        ["oye", "claude"], ["oye", "claud"], ["oye", "clod"], ["oye", "claudi"], ["ey", "claude"], ["ei", "claude"], ["hola", "claude"],
        ["hi", "claude"], ["hallo", "claude"], ["hello", "claude"], ["ok", "claude"], ["okay", "claude"], ["he", "claude"], ["hei", "claude"],
        ["claudi"], ["klaudi"], ["claudie"], ["klaudie"], ["clodi"], ["glaudi"],
    ]

    /// Helps the speech recognizer spell these words correctly
    static let contextualStrings = ["Hey Claude", "Oye Claude", "Claude", "Claudi"]

    /// Display text in the app
    static let displayName = "“Hey Claude”, “Oye Claude” or “Claudi”"

    static func normalize(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US")).lowercased()
    }

    /// Earliest wake word in the text, or nil
    static func match(in text: String) -> Match? {
        var words: [(word: String, range: Range<String.Index>)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { substring, range, _, _ in
            if let substring { words.append((normalize(substring), range)) }
        }
        for start in words.indices {
            for phrase in phrases where start + phrase.count <= words.count {
                let candidate = words[start..<(start + phrase.count)].map(\.word)
                if candidate == phrase {
                    return Match(commandStart: words[start + phrase.count - 1].range.upperBound)
                }
            }
        }
        return nil
    }

    /// Command after the wake word, without leading punctuation (“Hey Claude, what do you see?” → “what do you see?”)
    static func command(in text: String) -> String? {
        guard let match = match(in: text) else { return nil }
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return String(text[match.commandStart...]).trimmingCharacters(in: trimSet)
    }
}

/// Short two-tone chime as “I'm listening” feedback – generated in memory
/// and played over the active audio route (so also through the glasses).
@MainActor
final class Chime {
    static let shared = Chime()
    private var player: AVAudioPlayer?
    private let wav = Chime.makeWAV()

    func play() {
        do {
            let player = try AVAudioPlayer(data: wav)
            player.volume = 0.7
            player.play()
            self.player = player
        } catch {
            print("[Chime] Playback failed: \(error)")
        }
    }

    /// 16-bit mono WAV with two short sine tones (G5, D6) and soft edges
    private static func makeWAV() -> Data {
        let sampleRate = 44_100.0
        let tones: [(frequency: Double, seconds: Double)] = [(784, 0.09), (1175, 0.13)]
        var samples: [Int16] = []
        for tone in tones {
            let count = Int(sampleRate * tone.seconds)
            let fade = Int(sampleRate * 0.012)
            for i in 0..<count {
                let envelope = min(1.0, Double(min(i, count - i)) / Double(fade))
                let value = sin(2 * .pi * tone.frequency * Double(i) / sampleRate) * envelope * 0.45
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        samples.forEach { append($0) }
        return data
    }
}
