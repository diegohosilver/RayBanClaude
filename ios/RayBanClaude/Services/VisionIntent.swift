import Foundation

/// Decides whether a question needs a camera image – as with Meta AI, a photo is only taken then.
///
/// “What is this?”, “Read this out”, “What does the sign say?”, “Take a photo” → photo.
/// “Set a timer”, “What will the weather be like?” → no photo. If Claude asks for an image anyway,
/// it triggers one itself (tool request_photo/take_photo). When in doubt, no photo.
enum VisionIntent {
    /// Whole words that imply an image (“sieh mal”, “lies vor”, “look”) – not “sieht” as in “Wie sieht das Wetter aus?” (“What's the weather like?”)
    private static let visualWords: Set<String> = [
        "sieh", "siehst", "seht", "lies", "liest", "bild", "bilder", "qr", "look", "see", "read",
    ]

    /// Word prefixes that almost always imply an image (“schau” also matches “schaust”, “describ” matches “describe”)
    private static let visualStems = [
        "schau", "guck", "anschau", "anguck", "betracht", "lese", "vorles", "entziffer", "erkenn",
        "identifizier", "beschreib", "foto", "fotografier", "kamera", "knips",
        "schild", "etikett", "typenschild", "aufkleber", "zettel", "speisekarte", "menükarte", "verpackung",
        "display", "bildschirm", "barcode", "strichcode", "photo", "picture",
        "describe", "identif", "recogni", "camera", "snap", "label", "menu", "packag", "screen",
    ]

    /// Deictic phrases (“das hier”, “vor mir”, “this one”) – together with a question word, a request for an image
    private static let deicticPhrases = [
        "das hier", "dies hier", "der hier", "die hier", "das da", "dieses ding", "dieses teil",
        "vor mir", "in meiner hand", "hier vorne", "was ich sehe", "was ich gerade sehe",
        "this one", "this thing", "in front of me", "in my hand", "what i see", "what i'm looking at",
    ]

    /// Short questions that make no sense without an image
    private static let shortVisualQuestions = [
        "was ist das", "wer ist das", "was ist dies", "was sind das", "wie heißt das", "was kostet das",
        "wie viel kostet das", "welche farbe", "welches modell", "was für ein", "was für eine",
        "wie alt ist das", "ist das echt", "kann man das essen", "what is this", "what's this",
        "who is this", "what are these", "what does this say", "how much is this", "how much does this cost",
        "what color", "which model", "what kind of", "is this real", "can i eat this",
    ]

    static func needsImage(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let words = lowered.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        if words.contains(where: { word in visualWords.contains(word) || visualStems.contains { word.hasPrefix($0) } }) {
            return true
        }
        if deicticPhrases.contains(where: { lowered.contains($0) }) { return true }
        return shortVisualQuestions.contains { phrase in
            guard let range = lowered.range(of: phrase) else { return false }
            // “Was ist das?” at the end of a sentence – not “Was ist das Wetter morgen?”
            let rest = lowered[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return rest.isEmpty || rest.split(separator: " ").count <= 2 || phrase.hasPrefix("welch") || phrase.hasPrefix("was für") || phrase.hasPrefix("which") || phrase.hasPrefix("what color") || phrase.hasPrefix("what kind")
        }
    }
}
