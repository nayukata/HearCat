import FoundationModels

/// オンデバイスモデル(Apple Intelligence / FoundationModels)の共通処理。
/// 現状は要約(TranscriptSummarizer)から使う。
enum OnDeviceModel {
    /// モデルが使えない場合に日本語の理由を返す。使えるなら nil。
    static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "この Mac はオンデバイスモデル(Apple Intelligence)に対応していません"
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence が無効です。システム設定で有効にしてください"
            case .modelNotReady:
                return "モデルの準備中です。しばらくしてからもう一度お試しください"
            @unknown default:
                return "オンデバイスモデルを利用できません"
            }
        }
    }
}
