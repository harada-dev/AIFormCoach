import Foundation

/// PRD F2「参照コーチングDB」の初版。
///
/// **現時点ではコードに直書きしています。**JSONやサーバー配信への移行は
/// Alpha で行いますが、構造は最初から出典・確度・角度定義バージョンを
/// 持たせてあります。基準値の根拠が追跡できない状態を作らないためです。
///
/// **重要:** ここに載せる数値は3D座標・角度定義v2で測ったものでなければ
/// なりません。2D座標での計測値は撮影角度に依存するため比較できません。
enum ReferenceDatabase {

    // MARK: - 局面

    enum Phase: String, Sendable, CaseIterable {
        case approach = "踏み込み"
        case backswing = "バックスイング"
        case forwardSwing = "振り出し"
        case followThrough = "フォロースルー"
    }

    // MARK: - 測り方

    /// どのフレームから値を取るか。
    ///
    /// 足首のように小さく速く動く部位は、1フレームの値では推定誤差を
    /// そのまま拾ってしまいます。実測では同一動作の2本で13〜15°ずれました。
    /// 区間の中央値を取ると1〜2°まで縮みます。
    enum Sampling: Sendable {
        /// 膝が最も深く曲がったフレームの単一値。
        /// 膝角のように長い骨から計算する量は1フレームでも安定する（実測で再現性1°）。
        case backswingFrame

        /// 膝最深から指定ミリ秒までの区間に含まれる全フレームの中央値。
        ///
        /// 中央値を使うのは、区間内に1〜2枚の外れ値が混じっても結果が動かないため。
        /// 平均だと外れ値に引っ張られます。
        case forwardSwingMedian(windowMs: Int)

        var explanation: String {
            switch self {
            case .backswingFrame:
                return "膝が最も深く曲がったフレームの値"
            case .forwardSwingMedian(let ms):
                return "膝最深から\(ms)msの区間の中央値"
            }
        }
    }

    // MARK: - 合否の条件

    enum Tolerance: Sendable {
        case within(ClosedRange<Double>)
        case atLeast(Double)
        case atMost(Double)

        func acceptableSpan(in display: ClosedRange<Double>) -> ClosedRange<Double> {
            switch self {
            case .within(let range): return range
            case .atLeast(let value): return value...display.upperBound
            case .atMost(let value): return display.lowerBound...value
            }
        }

        func deviation(of value: Double) -> Double {
            switch self {
            case .within(let range):
                if value > range.upperBound { return value - range.upperBound }
                if value < range.lowerBound { return value - range.lowerBound }
                return 0
            case .atLeast(let minimum):
                return value < minimum ? value - minimum : 0
            case .atMost(let maximum):
                return value > maximum ? value - maximum : 0
            }
        }

        func describe(unit: String) -> String {
            switch self {
            case .within(let range):
                return "\(Int(range.lowerBound))〜\(Int(range.upperBound))\(unit)"
            case .atLeast(let value):
                return "\(Int(value))\(unit) 以上"
            case .atMost(let value):
                return "\(Int(value))\(unit) 以下"
            }
        }

        func boundary(for value: Double) -> Double? {
            switch self {
            case .within(let range):
                if value > range.upperBound { return range.upperBound }
                if value < range.lowerBound { return range.lowerBound }
                return nil
            case .atLeast(let minimum):
                return value < minimum ? minimum : nil
            case .atMost(let maximum):
                return value > maximum ? maximum : nil
            }
        }
    }

    enum Confidence: String, Sendable {
        case supervised = "監修済み"
        case provisional = "暫定値"
        case undetermined = "未確定"
    }

    struct Correction: Sendable {
        let reason: String
        let drillTitle: String
        let drillDetail: String
        let passLine: String
    }

    struct Metric: Sendable, Identifiable {
        let id: String
        let displayName: String
        let phase: Phase
        let sampling: Sampling
        /// 合否の条件。nil のときは基準値が未確定で、計測値の表示のみ行う。
        let tolerance: Tolerance?
        let unit: String
        let displayRange: ClosedRange<Double>
        /// PRD①「憧れの参照(言葉)」。選手名は使わない(パブリシティ権)。
        let aspiration: String
        let source: String
        let confidence: Confidence
        let angleDefinitionVersion: Int
        /// 撮影角度が真横から外れると信頼できない指標か。
        let requiresSideView: Bool
        /// 計測値によらず伝える一般的な指導ポイント。
        ///
        /// **数値による診断とは明確に区別すること。**測れていない数値を根拠に
        /// 「あなたはできていない」と言うのは根拠のない診断になります。
        /// ここに入れるのは「その動作では共通して大切なこと」だけです。
        let coachingNote: String?
        let whenAbove: Correction?
        let whenBelow: Correction?

        var isPrescribable: Bool { tolerance != nil }
    }

    // MARK: - サッカー / インステップシュート

    static let instepShot: [Metric] = [

        Metric(
            id: "knee_flexion_backswing",
            displayName: "蹴り足の膝の曲がり",
            phase: .backswing,
            sampling: .backswingFrame,
            tolerance: .within(90...110),
            unit: "°",
            displayRange: 60...180,
            aspiration: "トップ選手は蹴り足の膝を素早くたたんでバネを作ります。深くたたむほど、振り出しで解放できるエネルギーが大きくなります。",
            source: "PRD v1.2 §2 の例示値。Phase 0 実測で本気のキック時に106°を確認。動作強度に応じて155°→106°まで単調に変化(要監修)",
            confidence: .provisional,
            angleDefinitionVersion: 2,
            requiresSideView: false,
            coachingNote: nil,
            whenAbove: Correction(
                reason: "膝が伸びたまま振っているため、脚全体を振り回す動きになっています。バネが作れず、力がボールに集まりません。",
                drillTitle: "かかとをおしりに近づける素振り",
                drillDetail: "ボールなしで、振り上げたときにかかとがおしりに触れるくらいまで曲げる意識で20回。速く振らず、形を作ることを優先します。",
                passLine: "20回中15回、かかとがおしりに触れる"
            ),
            whenBelow: Correction(
                reason: "たたみが深すぎて、振り出しのタイミングが遅れている可能性があります。",
                drillTitle: "テンポを合わせた素振り",
                drillDetail: "「イチ、ニ」の2拍で振り上げから振り下ろしまで行う素振りを20回。",
                passLine: "20回を同じテンポで通せる"
            )
        ),

        Metric(
            id: "trunk_lean_backswing",
            displayName: "体幹の前傾",
            phase: .backswing,
            sampling: .backswingFrame,
            tolerance: .within(15...20),
            unit: "°",
            displayRange: 0...60,
            aspiration: "上体をわずかに前へ倒すことで、軸足の踏み込みが深くなり、下半身の力が上体に逃げずに脚へ伝わります。",
            source: "PRD v1.2 §2 の例示値。Phase 0 実測でしっかり蹴った際に15°を確認(要監修)",
            confidence: .provisional,
            angleDefinitionVersion: 2,
            requiresSideView: false,
            coachingNote: nil,
            whenAbove: Correction(
                reason: "前に倒れすぎているため、軸足に体重が乗り切らず、蹴り足の振りが小さくなります。",
                drillTitle: "壁タッチ素振り",
                drillDetail: "壁から一歩離れて立ち、頭が壁に触れない範囲で振る素振りを20回。前に突っ込む癖を抑えます。",
                passLine: "20回中18回、頭が壁に触れない"
            ),
            whenBelow: Correction(
                reason: "上体が立ちすぎているため、踏み込みが浅くなり、脚の振りだけで蹴る形になります。",
                drillTitle: "踏み込みを深くする素振り",
                drillDetail: "軸足を置く位置に印をつけ、そこへ強く踏み込んでから振る素振りを20回。",
                passLine: "20回中15回、印の位置に踏み込める"
            )
        ),

        // ── 足首の伸び:計測はするが処方はしない ─────────────────────
        //
        // 指導上は極めて重要な指標（足首が緩むと当たり負けして力が逃げる）。
        // しかし Phase 0 の実測で、現状の計測系では判別できないと結論した。
        //
        // 実測の内訳（すべて窓の中央値、真横撮影）:
        //   軽い素振り            92°, 93°
        //   足首を意識した素振り   100°
        //   足首を伸ばさずパス     105°   ← 意図的に緩めた
        //   ボール蹴り            107°
        //   本気の素振り          109°, 109°
        //   しっかり蹴った        111°   ← 意図的に伸ばした
        //
        // 問題:「伸ばした」111° と「伸ばさない」105° の差が 6° しかない。
        // 一方で足長（かかと-つま先）の変動係数は 23%（下腿は 5%）で、
        // 10cm の足に対して ±2.3cm の推定誤差 = 角度換算で 10° 以上。
        // **測りたい差が誤差より小さい。**
        // さらに値は「足首を伸ばす意識」よりも「振りの速さ」と相関していた。
        //
        // 根本原因は MediaPipe の足部キーポイント（かかと・つま先の2点）の
        // 推定精度が、この指標に必要な分解能に届いていないこと。
        // 復活させる正攻法は複数アングルからの3D推定（PRD 将来バックログ）。
        Metric(
            id: "ankle_plantarflexion_forward_swing",
            displayName: "足首の伸び",
            phase: .forwardSwing,
            sampling: .forwardSwingMedian(windowMs: 150),
            tolerance: nil,
            unit: "°",
            displayRange: 80...140,
            aspiration: "足首を伸ばして固定すると、足の甲が硬い一枚の面になります。当たり負けせず、力がそのままボールへ伝わります。",
            source: "足部キーポイントの推定誤差（足長の変動係数23%）が必要分解能に届かず、処方対象外とした。Phase 0 実測に基づく判断",
            confidence: .undetermined,
            angleDefinitionVersion: 2,
            requiresSideView: true,
            coachingNote: "インステップで蹴るときは、つま先を下に向けたまま足首を固定して当てるのが共通のポイントです。足首が緩むとボールが浮いたり、当たり所がずれやすくなります。椅子に座って足首を伸ばした形を5秒キープ×10回、そのあと止まったボールを足の甲の同じ場所で10本蹴る練習が効果的です。",
            whenAbove: nil,
            whenBelow: nil
        ),
    ]

    static func confidenceSummary(_ metrics: [Metric]) -> [Confidence: Int] {
        Dictionary(grouping: metrics, by: \.confidence).mapValues(\.count)
    }
}
