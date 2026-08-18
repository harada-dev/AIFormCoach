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

    /// 指標の合否条件。指標によって「範囲に収める」「これ以上あればよい」が異なる。
    ///
    /// 足首の伸びは伸びすぎて困ることが実質ないため、上限を設けると
    /// 誤って「伸ばしすぎ」と診断してしまいます。片側の条件が必要です。
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

        /// 条件から外れた量。範囲内なら 0。上に外れていれば正、下なら負。
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
        let tolerance: Tolerance?
        let unit: String
        let displayRange: ClosedRange<Double>
        /// PRD①「憧れの参照(言葉)」。選手名は使わない(パブリシティ権)。
        let aspiration: String
        let source: String
        let confidence: Confidence
        let angleDefinitionVersion: Int
        /// 撮影角度が真横から外れると信頼できない指標か。
        /// 足部を使う指標は正面撮影で足長が3割短く推定され、実測で13°ずれた。
        let requiresSideView: Bool
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
            source: "PRD v1.2 §2 の例示値。Phase 0 実測で本気のキック時に106°を確認(要監修)",
            confidence: .provisional,
            angleDefinitionVersion: 2,
            requiresSideView: false,
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
            source: "PRD v1.2 §2 の例示値(要監修)",
            confidence: .provisional,
            angleDefinitionVersion: 2,
            requiresSideView: false,
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

        // 小学生に非常によく見られる課題。足首が緩んでいると当たり負けして
        // ボールに力が伝わらない。
        //
        // 測り方(Phase 0 実測に基づく):
        //   膝最深から150msの区間で足首角が台地を作る。この台地の高さが
        //   「足首を固定して伸ばした状態」に対応する。1フレームの値では
        //   同一動作で13〜15°ずれたが、区間の中央値では1〜2°に収まった。
        //   150msという窓幅は、実測で台地がちょうど収まる長さとして決めた。
        //
        // 基準値 105° の根拠(暫定):
        //   軽い素振り 92°, 93° / 足首を意識した素振り 100°
        //   本気のキック 109°, 109° / ボール蹴り 107°
        //   この分布の谷にあたる 105° を暫定の合格線とした。
        //   **室内・控えめな強度での実測のため、屋外フルスイングでの
        //   上限側キャリブレーションが必要。監修による確定も未了。**
        Metric(
            id: "ankle_plantarflexion_forward_swing",
            displayName: "足首の伸び",
            phase: .forwardSwing,
            sampling: .forwardSwingMedian(windowMs: 150),
            tolerance: .atLeast(105),
            unit: "°",
            displayRange: 80...140,
            aspiration: "足首を伸ばして固定すると、足の甲が硬い一枚の面になります。当たり負けせず、力がそのままボールへ伝わります。",
            source: "Phase 0 実測（軽い素振り92〜93° 対 本気のキック107〜109°）の谷に置いた暫定値(要監修)",
            confidence: .provisional,
            angleDefinitionVersion: 2,
            requiresSideView: true,
            whenAbove: nil,
            whenBelow: Correction(
                reason: "足首が緩んだまま当たっているため、当たった瞬間に足が負けて力が逃げています。ボールが浮いたり、当たり所がずれる原因になります。",
                drillTitle: "つま先を伸ばして甲で当てる",
                drillDetail: "椅子に座り、足首を伸ばしてつま先を下に向けた形を5秒キープ×10回。そのあと止まったボールを、足の甲の同じ場所で10本蹴ります。強く蹴らず、当てる場所を揃えることを優先します。",
                passLine: "10本中7本、足の甲の同じ場所に当たる"
            )
        ),
    ]

    static func confidenceSummary(_ metrics: [Metric]) -> [Confidence: Int] {
        Dictionary(grouping: metrics, by: \.confidence).mapValues(\.count)
    }
}
