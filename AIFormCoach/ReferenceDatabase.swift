import Foundation

/// PRD F2「参照コーチングDB」の初版。
///
/// **重要:** ここに載せる数値は3D座標・角度定義v3で測ったものでなければなりません。
/// 各指標は角度の規約（屈曲角 / 内角 / 鉛直からのずれ）を明示的に持ちます。
/// 規約が計測側と一致しない指標は、診断エンジンが自動的に除外します。
enum ReferenceDatabase {

    // MARK: - 局面

    enum Phase: String, Sendable, CaseIterable {
        case approach = "踏み込み"
        case backswing = "バックスイング"
        case forwardSwing = "振り出し"
        case followThrough = "フォロースルー"
    }

    // MARK: - 測り方

    enum Sampling: Sendable {
        /// バックスイング最深（屈曲角が最大）のフレームの単一値。
        case backswingFrame
        /// 膝最深から指定ミリ秒までの区間の中央値。
        /// 足首のように小さく速く動く部位は、1フレーム値では SD 13〜15° になる。
        /// 区間の中央値にすると 1〜2° まで縮む。
        case forwardSwingMedian(windowMs: Int)

        var explanation: String {
            switch self {
            case .backswingFrame:
                return "バックスイング最深のフレームの値"
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
        /// **角度の規約。** 計測側と一致しない指標は診断から除外される。
        let convention: JointAngles.Convention
        let tolerance: Tolerance?
        let unit: String
        let displayRange: ClosedRange<Double>
        let aspiration: String
        let source: String
        let confidence: Confidence
        let angleDefinitionVersion: Int
        let requiresSideView: Bool
        /// 計測値によらず伝える一般的な指導ポイント。
        /// **数値による診断とは区別すること。**
        let coachingNote: String?
        /// 値が条件より大きいとき
        let whenAbove: Correction?
        /// 値が条件より小さいとき
        let whenBelow: Correction?

        var isPrescribable: Bool { tolerance != nil }
    }

    // MARK: - サッカー / インステップシュート

    static let instepShot: [Metric] = [

        // ── 膝屈曲（屈曲角。0° = 完全伸展） ────────────────────
        //
        // 規約について:
        //   実装当初は内角（180° = 完全伸展）で扱っていたため、PRD の値と
        //   約20°ずれていた。屈曲角に揃えると PRD・文献・実測が一致する。
        //     PRD v1.2 §2         90〜110°
        //     文献（PR #11 経由）  93.3〜111.8°
        //     実測（屋外実戦5本）  90〜113°
        //
        // 判定の向きに注意:
        //   屈曲角では「小さい = たたみが足りない」。内角のときと逆。
        //   実測で室内の軽い蹴り4本が 75〜82° と一貫して不足側に出た。
        Metric(
            id: "knee_flexion_backswing",
            displayName: "蹴り足の膝の曲がり",
            phase: .backswing,
            sampling: .backswingFrame,
            convention: .flexion,
            tolerance: .within(90...110),
            unit: "°",
            displayRange: 0...140,
            aspiration: "トップ選手は蹴り足の膝を素早くたたんでバネを作ります。深くたたむほど、振り出しで解放できるエネルギーが大きくなります。",
            source: "PRD v1.2 §2。文献（Cordeiro 2015 / Greig 2018、二次引用）および Phase 0 実測（屋外実戦 90〜113°）と整合。要監修",
            confidence: .provisional,
            angleDefinitionVersion: 3,
            requiresSideView: false,
            coachingNote: nil,
            whenAbove: Correction(
                reason: "たたみが深すぎて、振り出しのタイミングが遅れている可能性があります。",
                drillTitle: "テンポを合わせた素振り",
                drillDetail: "「イチ、ニ」の2拍で振り上げから振り下ろしまで行う素振りを20回。深さより、リズムを一定に保つことを優先します。",
                passLine: "20回を同じテンポで通せる"
            ),
            whenBelow: Correction(
                reason: "膝が伸びたまま振っているため、脚全体を振り回す動きになっています。バネが作れず、力がボールに集まりません。",
                drillTitle: "かかとをおしりに近づける素振り",
                drillDetail: "ボールなしで、振り上げたときにかかとがおしりに触れるくらいまで曲げる意識で20回。速く振らず、形を作ることを優先します。",
                passLine: "20回中15回、かかとがおしりに触れる"
            )
        ),

        // ── 足首の伸び:計測はするが処方はしない ─────────────────
        //
        // 指導上は極めて重要（足首が緩むと当たり負けして力が逃げる）。
        // しかし Phase 0 実測で判別できないと結論した。
        //   意図的に伸ばした 111° 対 伸ばさない 105° → 差 6°
        //   足長の変動係数 16〜29%（下腿は 5〜12%）→ 角度換算で 10° 以上の誤差
        // **測りたい差が誤差より小さい。** 全4群で改善せず、構造的な限界。
        // 規約の換算では解決しない（中間位が内角90°なので底屈角へ換算できるが、
        // 誤差の床は下がらない）。
        //
        // 復活の道筋: 複数アングルからの3D推定（PRD 将来バックログ）。
        Metric(
            id: "ankle_plantarflexion_forward_swing",
            displayName: "足首の伸び",
            phase: .forwardSwing,
            sampling: .forwardSwingMedian(windowMs: 150),
            convention: .interior,
            tolerance: nil,
            unit: "°",
            displayRange: 80...140,
            aspiration: "足首を伸ばして固定すると、足の甲が硬い一枚の面になります。当たり負けせず、力がそのままボールへ伝わります。",
            source: "足部キーポイントの推定誤差（足長の変動係数16〜29%）が必要分解能に届かず、処方対象外とした。Phase 0 実測に基づく判断",
            confidence: .undetermined,
            angleDefinitionVersion: 3,
            requiresSideView: true,
            coachingNote: "インステップで蹴るときは、つま先を下に向けたまま足首を固定して当てるのが共通のポイントです。足首が緩むとボールが浮いたり、当たり所がずれやすくなります。椅子に座って足首を伸ばした形を5秒キープ×10回、そのあと止まったボールを足の甲の同じ場所で10本蹴る練習が効果的です。",
            whenAbove: nil,
            whenBelow: nil
        ),

        // ── 体幹前傾:計測はするが処方はしない ──────────────────
        //
        // 「前傾15〜20°」は一次出典が確認できず撤回（PR #11）。
        // 該当しうる一次値は Alcock et al. 2012（エリート女子 n=15）の
        // −5.8 ± 8.3°、つまり平均 5.8° の**後傾**で、前傾15〜20°を支持しない。
        //
        // さらに Phase 0 実測で、後傾を意識した1本はシュートモーションが
        // 長くなる傾向を示した。実戦では不利益となりうるため推奨できない。
        //
        // 符号規約: 前傾を正、後傾を負。3D座標と前方向の判定が必須。
        Metric(
            id: "trunk_lean_backswing",
            displayName: "体幹の前傾",
            phase: .backswing,
            sampling: .backswingFrame,
            convention: .fromVertical,
            tolerance: nil,
            unit: "°",
            displayRange: -30...45,
            aspiration: "上体をわずかに前へ倒すことで、軸足の踏み込みが深くなり、下半身の力が上体に逃げずに脚へ伝わります。",
            source: "「前傾15〜20°」は一次出典が確認できず撤回。Alcock et al. 2012 は平均5.8°の後傾を報告しており支持しない。計測値のみ表示する",
            confidence: .undetermined,
            angleDefinitionVersion: 3,
            requiresSideView: false,
            coachingNote: "上体の前後の傾きは、踏み込み方や蹴り方の個性が出る部分です。実測では自然に蹴った場合に前傾18〜23°、意識して上体を残した場合に後傾5°と大きく変わりましたが、どちらでも深いバックスイングは作れていました。前傾・後傾のどちらが良いという基準は設けていません。なお上体を残すことを意識すると、振り始めから蹴り終わりまでの時間が長くなる傾向が観測されています。",
            whenAbove: nil,
            whenBelow: nil
        ),
    ]

    static func confidenceSummary(_ metrics: [Metric]) -> [Confidence: Int] {
        Dictionary(grouping: metrics, by: \.confidence).mapValues(\.count)
    }
}
