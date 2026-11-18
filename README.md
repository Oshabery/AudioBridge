# AudioBridge

iPhone で鳴っている音を近くの Mac に送り、Mac の通常の出力先（内蔵スピーカー、AirPods など）から **Mac 自身の音と一緒に** 鳴らすことを目指すプロジェクトです。

> **状態: 技術スパイク段階。** Linux のクラウド環境で書いたもので、**まだ一度もビルド・実行していません**。最初の `swift build` / `swift test` は Mac で行ってください。
> iOS 側（Media Device Extension）は未着手です。Apple の managed entitlement と iOS 27 SDK の確認待ちです。詳細は [docs/technical-feasibility.md](docs/technical-feasibility.md) を参照してください。

## 構成（目標）

```
iPhone (iOS 27+)                                            Mac
┌───────────────────────────────┐   Wi-Fi / P2P Wi-Fi   ┌──────────────────────────────┐
│ 任意のアプリ                  │   UDP "ABA1" PCM       │ AudioBridge Receiver          │
│   ↓ ユーザーが出力先ピッカーで │  ───────────────────▶  │  NWListener (_audiobridge._udp)│
│     「Mac」を選ぶ             │                        │  → StreamSequencer (欠落/遅延) │
│ Media Device Extension        │                        │  → SPSC ring buffer            │
│  + Audio Server Plug-in        │                        │  → AVAudioSourceNode           │
│    (RemoteStreaming デバイス)  │                        │  → AVAudioEngine → 既定出力    │
│  I/O callback → ring → 送信   │                        │    （他の Mac 音声と OS がミックス）│
└───────────────────────────────┘                        └──────────────────────────────┘
```

- `AudioBridgeCore`: プラットフォームに依存しない部品。リアルタイムスレッドで安全に使える（パケット形式、SPSC リングバッファ、シーケンサ、ジッタバッファ方針）。iOS 拡張でも再利用します。
- `AudioBridgeApple`: Network.framework による送受信と、AVAudioEngine による再生。
- `abrecv`: Mac 受信の CLI（スパイク S2）。
- `abtone`: 試験用の送信 CLI。iOS 拡張の代わりにトーンや音声ファイルを送ります。

### 音声フォーマットとバッファ
- 48 kHz / ステレオ / Int16 LE インターリーブ。1 パケット 5 ms（240 フレーム、1000 バイト）なので MTU に収まります。
- 受信側のジッタバッファの既定値は 60 ms です（`--target-ms` で変更できます）。
  - 不足（underrun）したときは無音で埋めて再バッファします。
  - 溜まりすぎ（250 ms 超）は目標値まで切り詰めます。
  - 送信側とのクロックのずれ（ドリフト）は、平滑化した充填量が ±10 ms を外れたときに 1 フレームを削除または複製して補正します。
- パケット欠落は sampleTime の差分で検出し、無音で補います（0.5 s 超の欠落はリセットします）。遅れて届いたパケットや重複パケットは捨てます。
- 再生スレッド（render callback）では、メモリ確保・ロック・ログ出力をしません。
- 出力デバイスやサンプルレートの変更（AirPods の接続など）は、既定出力の変更通知と `AVAudioEngineConfigurationChange` で検知し、engine を作り直します。
- **スパイクでは通信を暗号化していません。** 製品版では、ペアリングコードから PSK を導出して DTLS を使う予定です。

## スパイク S2: Mac 側の検証（entitlement 不要）

必要なもの: macOS 15 以降、Xcode 16 以降（Swift 6 toolchain）。

```bash
cd audio-bridge
```

```bash
swift build
```

```bash
swift test
```

ターミナル 1（受信）:

```bash
swift run abrecv --target-ms 60
```

ターミナル 2（送信: 同じ Mac または別の Mac）:

```bash
swift run abtone --seconds 60
```

- 初回は「ローカルネットワーク」へのアクセス許可を求められます。許可してください。拒否した場合は、システム設定 › プライバシーとセキュリティ › ローカルネットワーク で、使っているターミナルアプリを有効にします。
- トーンは左が 440 Hz、右が 660 Hz です。左右が正しく出ているか耳で確認できます。
- 音楽ファイルを送る場合: `swift run abtone --file ~/Music/sample.m4a`
- ネットワークが悪い状況の模擬: `swift run abtone --loss 0.02 --jitter-ms 30`

### 確認項目（結果は docs/spike-results.md に記録）
1. Mac で YouTube や Music を再生しながら `abtone` を送り、**両方が同時に聞こえる**か。
2. 再生中に出力先を AirPods に切り替える／AirPods を外す → 自動で追従するか。ログに `rebuilding engine` が出て音が戻るか。
3. `--loss 0.02 --jitter-ms 30` で、`lost` と `late` のカウンタが増え、途切れはあっても止まらないか。
4. 遅延:
   - 同じ Mac での送受信なら、ログの `transit` + `buffer` + `device` がおおよその合計遅延です。
   - 別の Mac 間では時計が揃っていないので、`transit` は使えません。音響ループバックで測ります: 送信機のスピーカー音と受信機の出力を 1 本のマイクで録り、波形のずれを測る。
5. CPU: Activity Monitor で `abrecv` の CPU 使用率を見ます。
6. Wi-Fi をオフ → オン: 再接続後に自動で鳴り始めるか。

## 次の段階（iOS）
1. Apple Developer Program に登録する（アカウント所有者として）。
2. Certificates, Identifiers & Profiles → App ID → Capability Requests で **Media Device Extension**（`com.apple.developer.media-device-extension`）を申請する。**日本で利用できるかは未確認です。**
3. Xcode 27 で iOS アプリ（拡張のインストールと使い方の説明だけを担う）と Generic Extension を作る。拡張は `MediaDeviceExtension` と `RealtimeSampleHandling` に準拠させる。
4. 拡張の中で Audio Server Plug-in（出力デバイス 1 つ、`kAudioDeviceTransportTypeRemoteStreaming`、UID = `MediaOutputDevice.id`）を `AudioServerPlugInRegisterMediaDeviceExtension` で公開し、I/O callback → `SPSCAudioRingBuffer` → 送信の流れを作る。

## 既知の制約
- iOS 側は iOS 27 以降と、Apple の承認が必要な entitlement が前提です。iOS アプリは拡張を届けて使い方を説明するためだけのアプリにする必要があります（DPLA 3.3.7 L）。
- 通話、DRM 保護コンテンツ、ロック中の挙動は未検証です。
- Bluetooth は音声の搬送路として使いません。

## プライバシー
- 音声はローカルネットワーク内で送受信するだけで、保存や外部送信はしません。
- スパイク版は平文の UDP です。信頼できるネットワークでのみ試してください。

## ライセンス
未定（作成者が決めてください）。
