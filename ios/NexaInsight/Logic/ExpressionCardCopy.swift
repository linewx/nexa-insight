import Foundation

/// Chinese labels for each study-item type.
///
/// Kept out of the view so the wording is testable, and so the eight types cannot
/// silently collapse into a three-way ternary the way the old card did — it
/// printed 词汇/短语/句式 and had no way to say a card was about a mishearing.
enum ExpressionCardCopy {
    static func typeLabel(_ type: LearningExpressionType) -> String {
        switch type {
        case .reduction: "连读弱读"
        case .ellipsis: "省略"
        case .syntax: "句法难点"
        case .idiom: "习语"
        case .reference: "背景知识"
        case .phrase: "短语"
        case .pattern: "句型"
        case .collocation: "搭配"
        case .word: "词汇"
        case .chunk: "口语惯用"
        }
    }
}
