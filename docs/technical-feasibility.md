# Audio Bridge: 技術的実現可能性の調査（初版 2026-11-18）

凡例: ✅ 確認済み（一次資料） / ❓ 未確認 / 🔬 実機でしか確認できない / ⚠️ 資料間で矛盾あり

調査方法: Apple Developer Documentation の JSON（`developer.apple.com/tutorials/data/documentation/...json`）を取得し、本文を読んだ。SDK ヘッダはまだ確認していない（Xcode が使える Mac が必要）。

## 結論（暫定）

- ✅ **Media Device Extension は、この用途に合った公開機構です。** 概要には「People can then stream to it from **any iOS app**, selecting your device from the media device picker. The picker is the same UI people use for AirPlay and Bluetooth output.」とある。
- ✅ **前提の訂正:** `AudioServerPlugInRegisterMediaDeviceExtension` は **iOS/iPadOS 27.0+（と Mac Catalyst 27.0+）の API** です。**iPhone 側**の拡張が `startRealtimeSampleDelivery(session:)` の中で呼ぶ。macOS の Audio Server Driver Plug-in を Mac 側に入れる設計ではない。
- ✅ 音声の流れ: iPhone のシステムがルート先の音をミックスする → iPhone 上の拡張が公開した Audio Server Plug-in の I/O コールバックで PCM を受け取る → AudioToolbox で符号化 → 独自プロトコルで送信。Creating a media device extension にはこうある:「receive the system audio through the audio server driver plug-in you publish (its I/O callbacks deliver the mixed audio), then use AudioToolbox to encode it」。
- **Mac 側は「受信機（ハードウェア）」の役です。** 普通の macOS アプリで受信・復号し、AVAudioEngine で**システムの既定出力**に再生する。こうすると Mac 自身の音とのミックスは Core Audio が自然に行い、AirPods への切替にも既定出力の追従で対応できる。Mac 側に仮想オーディオデバイスやドライバは**不要**。（この部分は設計判断で、🔬 実機確認が必要）
- ❗ 最大のリスクは**配布・権限**です（下記）。

## 1. 他アプリの通常再生音を Mac へ送れるか
- ✅ 「stream to it from any iOS app」「The system routes audio destined for that device through your extension」（`realtimeAudioStreaming` capability）。
- ❓ 通話音声、DRM／保護コンテンツ、`AVAudioSession` の設定によってはルートされない音があるか。資料に記載がない → 🔬
- ❓ ルートの単位（システム全体か、再生アプリ単位か）。picker は AirPlay と同じ UI だが、AirPlay audio と同じ範囲を扱うかは書かれていない → 🔬

## 2. 必要な OS・ターゲット・entitlement・署名
- ✅ MediaDevice / AVSystemRouting フレームワークは iOS 27.0+。
- ⚠️ ガイド「Routing and streaming media to remote devices」には「unavailable on Mac Catalyst and visionOS」とある。一方、シンボル個別ページには Mac Catalyst 27.0 の記載がある。→ **iOS のみが対象と扱う**。
- ✅ Xcode の Generic Extension ターゲットを使う。`EXAppExtensionAttributes.EXExtensionPointIdentifier = com.apple.media-device-extension`。
- ✅ `UTExportedTypeDeclarations` で `public.media-sharing-protocol` に準拠する UTI を宣言する。entitlement・UTI・`protocolType` の 3 つは同じ値にする。
- ⚠️ entitlement の値の形式が資料で食い違っている:
  - ガイドでは文字列 `com.example.sharingprotocol`
  - entitlement リファレンスでは配列で、`media-device-protocol.` という接頭辞が付く
  - → 実 SDK と Xcode の Capability で確認する。
- ✅ 「An app that holds this entitlement **can't hold any other managed entitlements**」なので、**managed entitlement**（Apple の承認が必要）。
- ✅ 「The container app's **sole purpose** must be the delivery and installation of the media device extension.」DPLA の定義も同じ趣旨。
- ❓ 申請窓口は Certificates, Identifiers & Profiles → App ID → Capability Requests と推測しているが、未確認。開発ビルドでも承認済みのプロファイルが必要と思われるが、未確認。
- ❓ **地域制限（EU のみか）**: 報道は DMA 対応として紹介している（下記の出典）。Apple の一次資料では確認できていない。
  - DPLA（2026-11-18 時点）の定義（「Media Device Extension」）と 3.3.7 L には、地域に関する記述が**ない**。ただし、そのことは「日本で使える」という証明にはならない。
  - **利用者は日本在住**。Developer Program への登録後に、(a) Capability Requests に申請項目が出るか、(b) 日本の iOS 27 実機で、第三者の出力先がピッカーに出るか、を確認する必要がある。🔬

## 3. Mac 側の出力とミックス
- 設計: Mac アプリが `NWListener` で受信 → 復号 → `AVAudioSourceNode` → `AVAudioEngine.outputNode`（既定出力）。Mac の他アプリの音と同じ出力デバイスで並行して再生される。🔬
- AirPods への切替: 既定出力の変更に追従して `AVAudioEngineConfigurationChange` を処理し、engine を再起動する。🔬

## 4. 制約
- ✅ 拡張は、system が activate したデバイスとだけ接続を保つ（「Only maintain connections to devices the system has activated」）。
- ✅ プラグインのデバイスは activate 後すぐに出現させる必要がある（「must appear promptly upon activation」）。間に合わないと「Unable to Connect」になる。
- ✅ プラグインは出力デバイス 1 つだけを公開する。transport type は `kAudioDeviceTransportTypeRemoteStreaming`、UID は `MediaOutputDevice.id` と一致させる。条件を満たさないと `kAudioHardwareIllegalOperationError` になる。
- ✅ NWBrowser を使う場合は `NSLocalNetworkUsageDescription` と `NSBonjourServices` が必要。
- ❓ 画面ロック、バックグラウンド、ネットワーク切断時の挙動 → 🔬
- 搬送路: 資料は発見手段として NWBrowser / CoreBluetooth / WiFiAware を挙げている。音声の搬送は Wi-Fi 上の Network.framework（TCP/UDP）を基本にする。Bluetooth を音声の搬送路としては前提にしない。

## 5. 代替案（MVP の範囲外になった場合）
- iOS アプリ**自身が再生する音だけ**を Network.framework で送る方式。**これは他アプリの音には対応しない**。「iPhone 全体の音声に対応」とは呼ばない。

## 出典
- https://developer.apple.com/documentation/mediadevice
- https://developer.apple.com/documentation/mediadevice/creating-a-media-device-extension
- https://developer.apple.com/documentation/mediadevice/realtimesamplehandling
- https://developer.apple.com/documentation/coreaudio/audioserverpluginregistermediadeviceextension
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.media-device-extension
- https://developer.apple.com/documentation/avsystemrouting/routing-and-streaming-media-to-remote-devices
- https://developer.apple.com/documentation/CoreAudio/creating-an-audio-server-driver-plug-in
- https://developer.apple.com/help/account/capabilities/capability-requests/
- https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- 報道（一次資料ではない。地域制限の手がかりとしてのみ使う）: https://9to5mac.com/2026/05/24/ios-27-google-cast-third-party-streaming-integration-eu/ , https://heise.de/-11307662
