# スパイク結果記録

未実施の項目は「未実施」と書く。数値は測定方法と一緒に記録する。

## 環境
| 項目 | 値 |
|---|---|
| Mac 機種 / macOS | 未記入 |
| Xcode / Swift | 未記入 |
| iPhone 機種 / iOS | 未記入 |
| ネットワーク（Wi-Fi 規格、同一 AP か） | 未記入 |

## S0: SDK の確認
| 確認 | 結果 |
|---|---|
| `MediaDevice.framework` が iOS 27 SDK にあるか | 未実施 |
| `AudioServerPlugInRegisterMediaDeviceExtension` が `AudioServerPlugIn.h` にあるか | 未実施 |
| entitlement の値の形式（文字列か配列か） | 未実施 |

## S2: Mac 受信
| # | 項目 | 結果 | メモ |
|---|---|---|---|
| 1 | `swift build` / `swift test` | 未実施 | |
| 2 | Mac 自身の音との同時再生 | 未実施 | |
| 3 | AirPods への切替と取り外し | 未実施 | |
| 4 | loss 2% / jitter 30 ms | 未実施 | |
| 5 | 遅延（同じ Mac: transit+buffer+device） | 未実施 | |
| 6 | 遅延（別の Mac 間: 音響ループバック） | 未実施 | |
| 7 | CPU 使用率 | 未実施 | |
| 8 | Wi-Fi の切断と復帰 | 未実施 | |
| 9 | ローカルネットワーク許可を拒否したときの表示 | 未実施 | |
