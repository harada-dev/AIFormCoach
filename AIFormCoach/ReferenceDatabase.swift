import Foundation

/// PRD F2「参照コーチングDB」の初版。
///
/// **現時点ではコードに直書きしています。**JSONやサーバー配信への移行は
/// Alpha で行いますが、構造は最初から出典・監修者・角度定義バージョンを
/// 持たせてあります。基準値の根拠が追跡できない状態を作らないためです。
///
/// **重要:** ここに載せる数値は3D座標・角度定義v2で測ったものでなければ
/// なりません。2D座標での計測値は撮影角度に依存するため比較できません。
enum ReferenceDatabase {

    // MARK: - 局面

    /// 動作の局面。指標ごとに「どのフレームで測るか」が変わる。
    /// 足首の伸びはインパクトの瞬間の指標であり、バックスイングで測っても意味がない。
    enum Phase: String, Sendable, CaseIterable {
        case approach = "踏み込み"
        case backswing = "バックスイング"
        case impact = "インパクト"
        case followThrough = "フォロースルー"

        /// 代表フレームの選び方。診断画面に出して透明性を持たせる。
        var frameSelectionNote: String {
            switch self {
            case .backswing:
                return "蹴り足の膝が最も深く曲がったフレーム"
            case .impact:
                return "バックスイング以降でつま先の速度が最大のフレーム"
            case .approach:
                return "収録開始直後"
            case .followThrough:
                return "収録終了直前"
            }
        }
    }

    // MARK: - 合否の条件

    /// 指標の合否条件。指標によって「範囲に収める」「これ以上あればよい」が異なる。
    ///
    /// 足首の伸びは伸びすぎて困ることが実質ないため、上限を設けると
    /// 誤って「伸ばしすぎ」と診断してしまう。片側の条件が必要。
    enum Tolerance: Sendable {
        /// 範囲内に収める
        case within(ClosedRange<Double>)
        /// この値以上あればよい
        case atLeast(Double)
        /// この値以下ならよい
        case atMost(Double)

        /// ゲージで緑に塗る範囲。
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

        /// 診断画面に出す目標の文字列。
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

        /// 条件を満たす境界値。目標までの差を出すのに使う。
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

    /// 基準値の確度。発表や監修の場で、どこが未確定かを明示するために持つ。
    enum Confidence: String, Sendable {
        /// 文献・指導者監修で裏付けが取れている
        case supervised = "監修済み"
        /// 暫定値。根拠はあるが監修前
        case provisional = "暫定値"
        /// 基準値が未確定。計測のみ行い処方はしない
        case undetermined = "未確定"
    }

    /// ずれの方向ごとの「理由」と「今日のドリル」。
    struct Correction: Sendable {
        /// なぜそれが問題なのか(PRDの「その理由」)
        let reason: String
        let drillTitle: String
        let drillDetail: String
        /// PRDの「合格ライン」
        let passLine: String
    }

    /// 1つの計測指標。
    struct Metric: Sendable, Identifiable {
        let id: String
        let displayName: String
        /// この指標をどの局面で測るか。
        let phase: Phase
        /// 合否の条件。nil のときは基準値が未確定で、計測値の表示のみ行う。
        let tolerance: Tolerance?
        let unit: String
        /// ゲージ描画用の表示範囲
        let displayRange: ClosedRange<Double>
        /// PRD①「憧れの参照(言葉)」。一流の動作を技術用語で言語化したもの。
        /// 選手名は使わない(パブリシティ権)。
        let aspiration: String
        /// 出典。空文字は根拠なしを意味する。
        let source: String
        let confidence: Confidence
        /// 角度定義バージョン。これが計測側と一致しない値は比較してはならない。
        let angleDefinitionVersion: Int
        /// 値が条件より大きいとき
        let whenAbove: Correction?
        /// 値が条件より小さいとき
        let whenBelow: Correction?

        var isPrescribable: Bool { tolerance != nil }
    }

    // MARK: - サッカー / インステップシュート

    static let instepShot: [Metric] = [

        // ── バックスイング ───────────────────────────────
        Metric(
            id: "knee_flexion_backswing",
            displayName: "蹴り足の膝の曲がり",
            phase: .backswing,
            tolerance: .within(90...110),
            unit: "°",
            displayRange: 60...180,
            aspiration: "トップ選手は蹴り足の膝を素早くたたんでバネを作ります。深くたたむほど、振り出しで解放できるエネルギーが大きくなります。",
            source: "PRD v1.2 §2 の例示値(要監修)",
            confidence: .provisional,
            angleDefinitionVersion: 2,
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
            tolerance: .within(15...20),
            unit: "°",
            displayRange: 0...60,
            aspiration: "上体をわずかに前へ倒すことで、軸足の踏み込みが深くなり、下半身の力が上体に逃げずに脚へ伝わります。",
            source: "PRD v1.2 §2 の例示値(要監修)",
            confidence: .provisional,
            angleDefinitionVersion: 2,
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

        // ── インパクト ───────────────────────────────────
        //
        // 小学生に非常によく見られる課題。足首が緩んでいると当たり負けして
        // ボールに力が伝わらない。インパクトの瞬間で測る必要がある。
        //
        // 基準値の根拠(暫定):
        //   この角度定義(膝→足首→つま先の内角)では、足首の中間位が約90°、
        //   完全に底屈した状態が130〜140°にあたる。Phase 0 の実測では
        //   1本目が最大110°(伸び不足)、2本目が142°(十分)で、この差が
        //   まさに指導上の課題に対応していた。そこで 125° 以上を暫定の
        //   合格線とする。**監修による確定が必要。**
        //
        // 伸びすぎて困ることは実質ないため .atLeast を使う。
        // .within で上限を設けると「伸ばしすぎ」という誤診断が出る。
        Metric(
            id: "ankle_plantarflexion_impact",
            displayName: "足首の伸び",
            phase: .impact,
            tolerance: .atLeast(125),
            unit: "°",
            displayRange: 60...170,
            aspiration: "足首を伸ばして固定すると、足の甲が硬い一枚の面になります。当たり負けせず、力がそのままボールへ伝わります。",
            source: "解剖学的可動域と Phase 0 実測レンジ(68〜142°)からの暫定値(要監修)",
            confidence: .provisional,
            angleDefinitionVersion: 2,
            whenAbove: nil,
            whenBelow: Correction(
                reason: "足首が緩んだまま当たっているため、当たった瞬間に足が負けて力が逃げています。ボールが浮いたり、当たり所がずれる原因になります。",
                drillTitle: "つま先を伸ばして甲で当てる",
                drillDetail: "椅子に座り、足首を伸ばしてつま先を下に向けた形を5秒キープ×10回。そのあと止まったボールを、足の甲の同じ場所で10本蹴ります。強く蹴らず、当てる場所を揃えることを優先します。",
                passLine: "10本中7本、足の甲の同じ場所に当たる"
            )
        ),
    ]

    /// 基準値の確度の内訳。発表や監修依頼のときにそのまま提示できる。
    static func confidenceSummary(_ metrics: [Metric]) -> [Confidence: Int] {
        Dictionary(grouping: metrics, by: \.confidence).mapValues(\.count)
    }
}
