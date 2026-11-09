import Foundation

/// A placeholder name for someone being invited: one color word and one creature word,
/// in the language of the device that creates the invitation. Never a person's name.
enum ProvisionalName {
    static let colors: [(ja: String, en: String)] = [
        ("青い", "Blue"), ("白い", "White"), ("緑の", "Green"), ("黄色い", "Yellow"),
        ("銀色の", "Silver"), ("金色の", "Golden"), ("茶色の", "Brown"), ("空色の", "Sky")]
    static let creatures: [(ja: String, en: String)] = [
        ("キツネ", "Fox"), ("カモメ", "Gull"), ("ウサギ", "Rabbit"), ("リス", "Squirrel"),
        ("ツバメ", "Swallow"), ("クジラ", "Whale"), ("ライチョウ", "Ptarmigan"), ("シカ", "Deer"),
        ("イルカ", "Dolphin"), ("フクロウ", "Owl"), ("ペンギン", "Penguin"), ("カワセミ", "Kingfisher"),
        ("ハヤブサ", "Falcon"), ("ヤマネ", "Dormouse")]

    static func all(japanese: Bool) -> [String] {
        colors.flatMap { color in
            creatures.map { creature in japanese ? color.ja + creature.ja : "\(color.en) \(creature.en)" }
        }
    }

    /// A combination not already in use; only when all are taken, a numbered one ("Blue Fox 2").
    static func candidate(japanese: Bool, avoiding used: Set<String>,
                          using generator: inout some RandomNumberGenerator) -> String {
        let names = all(japanese: japanese)
        if let free = names.filter({ !used.contains($0) }).randomElement(using: &generator) { return free }
        var number = 2
        while true {
            if let free = names.map({ "\($0) \(number)" }).first(where: { !used.contains($0) }) { return free }
            number += 1
        }
    }

    static func candidate(avoiding used: Set<String>) -> String {
        var generator = SystemRandomNumberGenerator()
        let japanese = Locale.current.language.languageCode?.identifier == "ja"
        return candidate(japanese: japanese, avoiding: used, using: &generator)
    }
}
