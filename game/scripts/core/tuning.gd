class_name Tuning
extends RefCounted
## 試作で置いた初期値（すべてここに集約する）。
## 仕様上 TBD の項目は「試作用の初期値」であり、確定値ではない。
##
## 単位:
##   距離 = マス（1マス = 1ワールド単位 = 現実の約3m）
##   時間 = シム秒（= 通常速度での実時間の秒数。速度切替で一緒に伸縮する）

# ---- 時間 ----
## ゲーム内時計の進み方: 通常速度で 24時間 = 300秒（仕様 3章）
const CLOCK_RATE := 86400.0 / 300.0
## 速度倍率（TBD・初期値）: 遅い=約10分 / 普通=約5分 / 早い=約2.5分
const SPEED_MULTS := [0.5, 1.0, 2.0]
const SPEED_LABELS := ["遅い", "普通", "早い"]
## 朝ピーク相当のループ（ゲーム内時刻・時）: 6:00〜10:00（4時間 = 通常速度で約50秒）
const LOOP_START_H := 6.0
const LOOP_END_H := 10.0
## シムの固定ステップ（シム秒）
const SIM_DT := 1.0 / 30.0

# ---- 地図（1交差点）----
const ARM_LEN := 12.0          # 交差点中心から各方向の道路の長さ
const ROAD_HALF := 1.0         # 道路の半幅（片側1車線 × 2）
const LANE_OFFSET := 0.5       # 車線中心の中心線からのずれ
const WALK_OFFSET := 1.5       # 歩道中心の位置
const CROSSWALK_T := 1.0       # 横断歩道の位置（歩道の角からの距離。中心から 2.5 マス）
const STOP_LINE_R := 3.2       # 信号の停止線（中心からの距離）
const BOX_REQ_R := 1.3         # 信号なしで交差点進入を待つ位置
const DOOR_T_MIN := 1.0        # 発生・吸収エリアの出入口（歩道の角からの距離）の範囲
const DOOR_T_MAX := 8.0
const DOOR_NEAR_BIAS := 2.0    # 出入口の分布の偏り（大きいほど交差点寄りに集まる）
const CAR_DOOR_R_MIN := 4.5    # 車の出入口（中心からの距離）の範囲
const CAR_DOOR_R_MAX := 9.0

# ---- 車両 ----
const CAR_SPEED := 4.0         # 巡航速度（マス/秒）
const CAR_BOX_SPEED := 2.4     # 交差点内の速度
const CAR_ACCEL := 4.0
const CAR_DECEL_COMFORT := 4.0
const CAR_DECEL_MAX := 9.0     # 急ブレーキの上限。歩行者はこれで止まれる車の前にだけ出る
const CAR_LENGTH := 0.8
const CAR_WIDTH := 0.42
const CAR_GAP_CAR := 0.75      # 前方の車に対する停止余裕（車間が見える程度）
const CAR_GAP_PED := 0.6       # 歩行者の横断線に対する停止余裕（車の中心から）
const CAR_DETECT_R := 0.5      # 進路上の車を障害物とみなす横方向の半径
const CAR_DETECT_R_PED := 0.45 # 横断中の歩行者の通り道（線）までの距離がこれ未満なら止まる
const CAR_LOOKAHEAD := 2.0
## 信号なしの交差点で、交差する車と鉢合わせたときのためらい時間（譲り合わない混乱の表現）
const CAR_STANDOFF_MIN := 0.8
const CAR_STANDOFF_MAX := 2.2
## ヒヤリ（急ブレーキ）とみなす減速度
const HIYARI_DECEL := 5.0

# ---- 歩行者 ----
const PED_SPEED := 1.3
const PED_RADIUS := 0.15
## 信号のある横断歩道を使う条件: 迂回距離がこの値（マス）以内なら使う（初期値）
const PED_DETOUR_MAX := 6.0
## 歩行者用の青が残りこの秒数未満なら渡り始めない
const PED_MIN_GREEN_LEFT := 2.5
## 渡り始める前に確認する車の範囲: 停止距離 + 余裕
const PED_SAFETY_MARGIN := 0.6

# ---- 信号機 ----
const SIGNAL_COST := 100
const START_FUNDS := 300
const DEMOLISH_REFUND_RATE := 0.5
## 間隔プリセット（TBD・初期値）: 1方向あたりの青の長さ（シム秒）
const SIGNAL_PRESET_LABELS := ["短い", "普通", "長い"]
const SIGNAL_GREEN := [5.0, 8.0, 12.0]
const SIGNAL_YELLOW := 2.0
const SIGNAL_ALL_RED := 1.5

# ---- 発生プロファイル（朝ピークの簡易版）----
## 発生率（体/シム秒）= BASE + PEAK * exp(-((時刻 - PEAK_H) / PEAK_W)^2)
const PED_RATE_BASE := 0.4
const PED_RATE_PEAK := 4.0
const CAR_RATE_BASE := 0.3
const CAR_RATE_PEAK := 3.0
const PEAK_H := 7.4
const PEAK_W := 0.6

# ---- 不満度 ----
## 個人不満（0〜100）の増減（1シム秒あたり）
const D_WAIT_PED := 6.0        # 車の切れ目を待つ歩行者（危険を伴う待ち。許容時間を超えた後）
const D_WAIT_PED_SIGNAL := 4.0 # 赤信号で待つ歩行者（秩序ある待ち。許容時間を超えた後）
const WAIT_TOLERANCE_SIGNAL := 4.0  # 赤信号での待ちの許容時間
const D_WAIT_CAR := 5.0        # 止まっている車（許容時間を超えた後）
const WAIT_TOLERANCE := 2.0    # この秒数までの連続した待ちは不満にならない
const D_DELAY := 3.0           # 期待所要時間 × DELAY_FACTOR を超えた後
const DELAY_FACTOR := 1.25
const D_HIYARI_PED := 15.0     # ヒヤリの瞬間（1回あたり）
const D_HIYARI_CAR := 10.0
const D_HIYARI_NEARBY := 6.0   # ヒヤリを近くで見た人（半径 HIYARI_NEARBY_R）
const HIYARI_NEARBY_R := 2.0
const D_DECAY := 1.0           # 動いている間の減衰
const CONTAGION_R := 1.2       # 不満の伝染の半径
const CONTAGION_RATE := 0.15   # 近くで待つ人との差を縮める速さ
## 街全体のゲージ = Σ個人不満 ÷ max(人数, GAUGE_POP_FLOOR)
## （人が少ない時間帯に、残った数人の不満だけでゲージが振り切れないようにする下限）
const GAUGE_POP_FLOOR := 25.0
## 街全体のゲージの追従の速さ（大きいほど速い）
const GAUGE_SMOOTH := 1.5
## 敗北条件: ゲージが上限のまま ゲーム内2時間（仕様 3章・決定済み）
const GAUGE_LIMIT := 99.5
const FAIL_GAME_SECONDS := 7200.0

# ---- 第1弾: 波の演出・熱マップ・光 ----
## 設置の瞬間に広がる「安心の波」（ルール追加。Muse の確認待ちの暫定値）
const WAVE_SPEED := 14.0       # 波の広がる速さ（マス/シム秒）
const WAVE_MAX_R := 14.0
const WAVE_RELIEF := 0.2       # 波が通った人の不満を、この割合だけ減らす（ユーザー決定: 約20%）
## 渋滞の熱マップ: 待っている人がいたセルに熱がたまり、ゆっくり冷める
const HEAT_TAU := 25.0         # 冷める速さ（シム秒）
const HEAT_FULL := 8.0         # この値で最も赤くなる
## 24時間表示（光の確認用）での夜間の発生量（朝6時〜21時は 1.0）
const NIGHT_ACTIVITY := 0.2
const EVENING_PEAK_H := 17.5
const EVENING_PEAK_RATIO := 0.8

# ---- 第3弾: ステージ1の地図（試作で置いた初期値）----
## 建物から出る人の予定表（予報どおりに確定。毎回同じ）
const T_SEED := 20261124
const T_COMMUTERS_PER_HOME := 10     # 通勤者（家→オフィス。朝）
const T_CHILDREN_PER_HOME := 22      # 児童（家→学校。朝）
const T_SHOPPERS_PER_HOME := 3       # 買い物客（家→商店。昼）
const T_COMMUTE_MORNING := [6.9, 9.0]
const T_COMMUTE_EVENING := [17.0, 19.3]
const T_SCHOOL_GO := [7.3, 8.5]
const T_SCHOOL_BACK := [15.0, 16.5]
const T_SHOP_GO := [9.5, 15.5]
const T_SHOP_BACK := [11.0, 17.5]
## 手段: 家からオフィスまでの距離（マス）で車の割合が変わる
const T_CAR_DIST_MIN := 6.0
const T_CAR_DIST_SPAN := 24.0
const T_CAR_SHARE_MIN := 0.25
const T_CAR_SHARE_MAX := 0.9
## 通過交通（ランダム。量だけが毎ループ少し変わる）
const T_THROUGH_CAR_BASE := 0.10
const T_THROUGH_CAR_PEAK := 0.35
const T_THROUGH_PED_BASE := 0.03
const T_THROUGH_PED_PEAK := 0.08
## 信号の連動（自動）
const T_LINK_DIST := 20.0            # この距離（マス）以内の信号同士が、同じ道路・同じ間隔でつながる
const T_XWALK_MIN_FROM_JUNCTION := 5.0
const T_XWALK_MIN_GAP := 3.5
## 車が長く止まり続けたときの救済（完全な詰まりを避ける）
const T_BREAKER_WAIT := 20.0
## ステージ1の試作ループ（ゲーム内時刻）。渋滞のピークがループの中に収まるよう、朝〜昼前まで
const T_LOOP_START := 6.0
const T_LOOP_END := 12.0
## 連動のずれの計算: 信号から信号までの実効の速さ（停止からの発進と交差点内の減速を含む。実測で約2.3）
const T_WAVE_SPEED := 2.3
## 連動で優先する向き: この時間帯（朝の通勤）の車が多い向き
const T_FAV_WINDOW := [6.5, 9.5]
