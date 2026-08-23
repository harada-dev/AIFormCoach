import Foundation

/// PRD F2「参照コーチングDB」の初版。
///
/// **現時点ではコードに直書きしています。**JSONやサーバー配信への移行は
/// Alpha で行いますが、構造は最初から出典・確度・角度定義バージョンを
/// 持たせてあります。基準値の根拠が追跡できない状態を作らないためです。
///
/// **重要:** ここに載せる数値は3D座標・角度定義v2で測ったものでなければ
/// なりません。2D座標での計測値は撮影角度に依存するため比較できません。
///
/// **角度の向きの定義も各エントリに明記してください。**同じ数値に対して
/// 別の文書が別の定義（例: 180°=完全伸展 と 0°=完全伸展）を主張すると、
/// 合否判定が静かに反転します。`knee_flexion_backswing` で実際に起きました。
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
        ///
        /// **2文以内。1文目にポイント、2文目に練習。それ以外は書かないこと。**
        /// 読み手は小学生です。指示より先に弁明(「根拠がありません」等)を置くと、
        /// その後の指示が読まれません。基準値が未確定である旨は
        /// `DiagnosisView.referenceOnlySection` が計測値のすぐ下で、
        /// 根拠と撤回理由は `source` が最下段で、それぞれ既に述べています。
        /// ここで繰り返さないこと。
        let coachingNote: String?
        let whenAbove: Correction?
        let whenBelow: Correction?

        var isPrescribable: Bool { tolerance != nil }
    }

    // MARK: - サッカー / インステップシュート

    static let instepShot: [Metric] = [

        // ── 蹴り足の膝の曲がり:角度定義の衝突が判定を反転させるため処方対象外 ──
        //
        // 【角度の向きの定義】このアプリの `JointAngles.kneeFlexion` は
        // 股関節-膝-足首の**内角**で、180° = 完全伸展、値が小さいほど深く
        // 折りたたまれている。一方、本プロジェクトのエビデンス台帳は同じ
        // PRD の数値を「0° = 完全伸展」の屈曲角として記載していた。
        // 1つの数値について2つの文書が正反対の定義を主張しており、
        // その数値で合否を判定していた。再発を防ぐため定義をここに明記する。
        //
        // 【文献値を内角に換算すると 90〜110° の窓の下に外れる】
        //   Cordeiro et al. 2015, Knee Surg Sports Traumatol Arthrosc 23:1100-6
        //     (ポルトガルリーグ n=9。最大伸展を −0.1 ± 0.1° と報告しており、
        //      0°=完全伸展の定義であることが確認できる)
        //     最大膝屈曲 93.3 ± 5.2°  → 内角 ≒ 86.7°
        //   Greig 2018, J Appl Biomech 34(4):278-83
        //     (Petrolo et al. の系統的レビュー経由の**二次引用**)
        //     最大膝屈曲 111.8 ± 7.1° → 内角 ≒ 68.2°
        //
        //   → エリート成人の帯は、このアプリの内角換算で概ね **68〜87°**。
        //     コードの窓 90〜110° はこの帯の完全に上側にあり、文献どおりに
        //     深くたたんだ選手は whenBelow「たたみが深すぎる」と判定される。
        //     下の source にある実測 106° は内角読み(屈曲 ≒ 74°)と整合し、
        //     文献の帯より浅い。
        //     ※この換算値は次に帯を決める人のための参考であり、
        //       基準値として採用はしていない(下記のとおり最適値の根拠が無い)。
        //
        // 【サンプリングする瞬間】最大膝屈曲は limb cocking の終わり
        //   (キック動作の 63.6 ± 5.2%: Langhout et al. 2016,
        //    J Sports Med Phys Fitness 56(7-8):849-56。Petrolo et al. の
        //    系統的レビュー経由の**二次引用**、原著未入手・サンプリング周波数不明)
        //   に生じ、バックスイングの終わり(股関節最大伸展)とは別の瞬間。
        //   ただし `DiagnosisEngine.deepestKneeFlexion()` は実際には
        //   「膝の内角が最小のフレーム」を探しているので、取得している瞬間
        //   そのものは最大膝屈曲で正しい。誤っているのは `Phase.backswing` と
        //   `Sampling.backswingFrame` という**名前**だけである。
        //   Phase enum に limb cocking を表す case が無いため、ここでは
        //   名前を変えずに事実の記録にとどめた(改名の判断は維持者に委ねる)。
        //
        // 【そもそも最適値を支持する研究が無い】
        //   Sinclair et al. 2014, Eur J Sport Sci 14(8):799-805
        //     (n=22 アカデミー, 500 Hz): ボール速度の有意な予測因子は
        //     インパクト時の膝伸展**速度**のみ(調整済み R²=0.39, p≤0.01)。
        //     角度変数はどれもモデルに残らなかった。
        //   Kapidžić et al. 2014, J Hum Kinet 42:81-90
        //     (n=13, 13 ± 0.5歳 = 本アプリの対象年齢): 膝角変数は回帰に入らず、
        //     インパクト時の足の速度と軸足-ボール距離のみが寄与した。
        //   Blair et al. 2020, PLOS ONE 15(11):e0241969: 正確なキックほど
        //     可動域が**小さい**ため、単一の最適値を定義できない。
        //
        // → 合否の窓を置ける根拠が無いので `tolerance` を nil にし、
        //   PR #8 の足首と同じ「計測はするが処方はしない」表現に寄せた。
        //   ドリルの内容は coachingNote に移して保存してある。
        Metric(
            id: "knee_flexion_backswing",
            displayName: "蹴り足の膝の曲がり",
            phase: .backswing,
            sampling: .backswingFrame,
            tolerance: nil,
            unit: "°",
            displayRange: 60...180,
            aspiration: "トップ選手は蹴り足の膝を素早くたたんでバネを作ります。深くたたむほど、振り出しで解放できるエネルギーが大きくなります。",
            source: "PRD v1.2 §2 の例示値(要監修)。文献(Cordeiro et al. 2015 / Greig 2018〈二次引用〉)の内角換算帯は 68〜87°。2026-08-21 実測(スパイク着用の実戦形3本)で内角 60〜77° を確認し、文献帯とほぼ一致した(室内の素振りでは内角106°どまりで到達しない)。例示値の窓 90〜110° のみが両者から外れる。角度の最適値を支持する研究は無く、ボール速度の有意な予測因子はインパクト時の膝伸展速度のみ(Sinclair et al. 2014)。以上より基準値未確定として処方対象外とした",
            confidence: .undetermined,
            angleDefinitionVersion: 2,
            requiresSideView: false,
            // 【退避】基準値が戻ったときに whenAbove / whenBelow へ復帰させる予備ドリル。
            //   ・速く振るより形を作るのが先。
            //   ・振り出しが遅れる感じがあるときは「イチ、ニ」の2拍で
            //     振り上げから振り下ろしまで通す素振りを20回、同じテンポで。
            coachingNote: "振り上げで膝をたたむと、その分だけ強く振り出せます。かかとがおしりに近づくくらい曲げる素振りを20回。",
            whenAbove: nil,
            whenBelow: nil
        ),

        // ── 体幹の前傾:15〜20° を支持する出典が無いため処方対象外 ────────
        //
        // 【角度の向きの定義】このアプリの `JointAngles.trunkLean` は
        // 「肩中点→腰中点のベクトルが鉛直から何度傾いているか」で、**符号を持たない**。
        // 3D では左右への側屈も同じ量に混ざるので、前傾・後傾・側屈を区別できない。
        // 15〜20° の窓は前傾を意図しているが、現在の計測は「前傾18°」「後傾18°」
        // 「側屈18°」をすべて 18° として返す。窓を置く前にここを直す必要がある。
        //
        // 【15〜20° を支持する出典が無い】文献値は定義ごとに大きく異なる:
        //   Alcock et al. 2012, J Sports Sci 30(4):387-94
        //     (エリート女子 n=15。体幹の対鉛直グローバル角) −5.8 ± 8.3°
        //     = 平均 5.8° の「**後**傾」。符号を持たない現在の計測では
        //     そもそも前傾と区別して表現できない。
        //   脊椎の相対屈曲角 41.4 ± 8.8°(**二次引用**)
        //   → どちらも 15〜20° の近傍に無く、2つの定義は互いに両立しない。
        //     つまり「体幹角」と一言で言っても何を測るかで値が桁違いに変わる。
        //
        // 【成人アマチュアでも体幹の「角度」は効いていない】
        //   n=50 の研究(PubMed 39462302)では体幹**角度**はパフォーマンスの
        //   モデルに入らず、寄与したのは体幹の**モーメント**だった
        //   (Rc=0.74, p<.001)。モーメントは単眼カメラの映像からは求められない。
        //
        // → 合否の窓を置ける根拠が無いので `tolerance` を nil にした。
        //   ドリルの内容は coachingNote に移して保存してある。
        Metric(
            id: "trunk_lean_backswing",
            displayName: "体幹の前傾",
            phase: .backswing,
            sampling: .backswingFrame,
            tolerance: nil,
            unit: "°",
            displayRange: 0...60,
            aspiration: "上体をわずかに前へ倒すことで、軸足の踏み込みが深くなり、下半身の力が上体に逃げずに脚へ伝わります。",
            source: "PRD v1.2 §2 の例示値(要監修)。文献値は −5.8 ± 8.3°(Alcock et al. 2012、対鉛直グローバル角=後傾)と 41.4 ± 8.8°(脊椎相対屈曲角、二次引用)で、どちらも 15〜20° の近傍になく定義も両立しない。2026-08-21 実測(3本)では自然体 +18° / +23°、後傾を意識した1本が −5° と意図が数値に出たが、その1本は膝最深→最大伸展が最長(1107ms)で、後傾が速さに寄与する証拠は無くモーションが延びる可能性がある。推奨は実戦上の不利益を生みうるため処方対象外を維持する。なお現在の計測は符号を持たず前傾・後傾・側屈を区別できない",
            confidence: .undetermined,
            angleDefinitionVersion: 2,
            requiresSideView: false,
            // 【退避】基準値が戻ったときに whenAbove / whenBelow へ復帰させる予備ドリル。
            //   ・軸足を置く位置に印をつけ、そこへ踏み込んでから振る素振りを20回。
            //   ・前へ突っ込む癖があるときは、壁から一歩離れて立ち、
            //     頭が壁に触れない範囲で振る素振りを20回。
            // ただし「踏み込め」は後傾を誘発しうる助言なので、復帰させる前に
            // 2026-08-21 実測(source 参照)を踏まえて表現を見直すこと。
            coachingNote: "上体を前に倒すか後ろに残すかは人それぞれです。ここは気にせず、膝をたたむことに集中しましょう。",
            whenAbove: nil,
            whenBelow: nil
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
            source: "足部キーポイントの推定誤差(足長の変動係数23% = 角度換算10°超)が必要分解能に届かず処方対象外とした。実測では意図的に伸ばした111°と緩めた105°の差が6°しかなく、測りたい差が誤差より小さい。足首が緩むと当たり負けして力が逃げる点は指導上重要だが、「何度が正解」を言える根拠は無い。復活には複数アングルからの3D推定が必要。Phase 0 実測に基づく判断",
            confidence: .undetermined,
            angleDefinitionVersion: 2,
            requiresSideView: true,
            // 【退避】基準値が戻ったときに whenAbove / whenBelow へ復帰させる予備ドリル。
            //   ・足首が緩むとボールが浮いたり、当たり所がずれやすくなる。
            //   ・止まったボールを足の甲の同じ場所で10本蹴る。
            coachingNote: "つま先を下に向けて、足首を固定したまま当てます。座って足首を伸ばす形を5秒キープ×10回。",
            whenAbove: nil,
            whenBelow: nil
        ),
    ]

    static func confidenceSummary(_ metrics: [Metric]) -> [Confidence: Int] {
        Dictionary(grouping: metrics, by: \.confidence).mapValues(\.count)
    }
}
