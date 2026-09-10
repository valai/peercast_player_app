# ネイティブコアの統合状況

PeerCast YTをDart FFIから起動し、端末内のHTTPストリームをAndroidではvideo_player（Media3）、iOSではmedia_kitで再生します。外部の視聴変換サービスは使いません。

## 構成

- 上流コア: https://github.com/plonk/peercast-yt / b60f176317406e79a5468ba80da8be1d83bb6126
- TLS依存: https://boringssl.googlesource.com/boringssl / 4a92579453b35319e2707eab68a0b7d1f8d5d053
- 固定リビジョン: native/dependencies.json。prepare-nativeスクリプトで取得・検証。
- native/mobile/CMakeLists.txt: Android/iOS共通ライブラリ。上流コピーに移植差分を適用し、元のcheckoutは変更しません。
- bridge.cpp: 起動・接続・統計・リレー設定・停止のC API。Dartの専用Isolateから直列に呼び出します。
- playback_controller.dart: Wi-Fi限定、接続タイムアウト、回線喪失、画面終了・バックグラウンド停止、プラットフォーム別プレーヤーとの接続。

## 移植差分

Androidで `_BIG_ENDIAN` がバイト順を示す真偽値ではなく定数として定義されるため、コンパイラの `__BYTE_ORDER__` で判定します。未修正ではPCPの整数フィールドが逆順になり、上流への接続に失敗しました。

新しいlibc++向けのバイト文字列traitsとconst比較、Android/iOSのスレッド・ネットワーク列挙を補完しています。外部プロセス、旧Carbon API、上流内蔵YP取得・アップロードテストサービスは使いません。

待受開始前にネットワーク用途だけを許可し、HTTPは選択チャンネルのPCPとループバック限定の再生URLに制限します。管理・ファイル・投稿・配信開始の経路は拒否します。既定の下流上限は1で、ローカル下流にも上限を適用します。リレー停止時は既存下流を切断し、新規接続も拒否します。

停止時は通信を中断し、コアのワーカー終了を待ってから再利用します。12秒以内に終了しない場合は成功扱いにせず、アプリ再起動を案内します。画面ごとの所有トークンで古い画面の遅延停止から新しい視聴を保護します。

到達性はコアの実測状態を表示します。ポートのbind成功だけで「接続可能」と表示しません。外部送信量はループバック・LAN通信を除くコア統計です。

## 再生バックエンド

Android API 36エミュレーターで、media_kitのGPU出力がEGL_BAD_ATTRIBUTEとなり、複数のチャンネルで黒画面になりました。SwiftShaderでも再現したため、Androidはvideo_playerのMedia3バックエンドを使います。iOSはFLV用のmedia_kitを継続します。再生の初期化には30秒のタイムアウトを設けています。

## 検証（2026-09-08）

Android x86_64エミュレーター上で以下を確認しました。

- ポート未開放判定の環境で、実SPチャンネルを受信しローカルHTTPからFLVヘッダーを取得。
- 2つのコアを127.0.0.1の別ポートで接続し、上流の下流接続数1・下流のFLV受信を確認。
- 管理HTTP要求への403、リレー無効時の新規接続拒否、停止後の待受終了、繰り返し起動・停止。
- Androidアプリで複数の検証対象チャンネルの映像・掲示板同時表示と全画面切り替えを確認。
- バックグラウンド移行後のコア待受・受信終了、ExoPlayer解放、復帰後の停止表示を確認。
- Flutter静的解析・13件のテスト・Android APKビルド成功。

外部ポートが開いていないため、インターネット側からの着信・実外部下流へのリレーは未確認です。30分連続視聴、Android実機、iOSビルド・実機、掲示板投稿も未確認です。

## ネイティブの再検証

NDKのCMakeツールチェーンで `-DANDROID_ABI=x86_64 -DANDROID_PLATFORM=android-24 -DPEERCAST_SMOKE_TEST=ON` を指定し、peercast_smokeターゲットをビルドします。

エミュレーターの/data/local/tmpへpeercast_smoke、libpeercast_mobile.so、NDKのlibc++_shared.soを配置し、実行権限を付けます。

```sh
cd /data/local/tmp
LD_LIBRARY_PATH=. ./peercast_smoke
LD_LIBRARY_PATH=. ./peercast_smoke CHANNEL_ID TRACKER_HOST:PORT 17144 60
# 上記受信中に、別のシェルから下流を接続
LD_LIBRARY_PATH=. ./peercast_smoke CHANNEL_ID 127.0.0.1:17144 17145 25
```

実チャンネル試験は対象が配信中である必要があります。引数なしの試験は外部配信に依存しません。

## 依存ライセンス

PeerCastコア・BoringSSLの原文をassets/licensesへ同梱し、設定のライセンス画面から表示します。Dart依存のライセンスはFlutterの登録を利用します。採用バージョンはpubspec.lockに記録しています。

Androidのmedia_kit_libs_android_video 1.3.8は以下のネイティブビルドを使います。
https://github.com/media-kit/libmpv-android-video-build/tree/v1.1.7

一般配布向けのライセンス整理・対応ソース一式の配布パッケージ作成は未実施です。このリポジトリの移植差分とprepare-nativeスクリプトを、上流ソースと合わせて保持してください。


## 視聴条件

視聴・リレーにはWi-Fi接続と設定ポートの外部到達確認が必要です。
`pc_start` は待受のみを開始します。`pc_check_port` は配信元トラッカーに
PCPの逆接続確認を非同期で要求し、成功後に限り `pc_connect` を許可します。
未確認の間はチャンネル取得とリレーを開始しません。一覧・掲示板の閲覧は独立しています。
IPv4の外部到達確認に対応しており、確認に対応しない配信元やIPv6のみの場合も視聴を許可しません。

視聴中は15秒ごとに再確認し、失敗・未確認状態または確認開始から30秒の期限超過を
1秒周期の監視で検出して映像とリレーを停止します。Wi-Fi喪失は接続変更通知でも停止します。
リレー上限は1〜16で、0の旧設定は1に移行します。単独でリレーを停止する操作はありません。
ネイティブAPIを追加したため、反映にはアプリの再ビルドが必要です。


### 開放確認の成功応答と終了処理

PCP OLEHのセッションID・外部IP・ポートを検証した後のQUIT送信は、終了通知にすぎません。
確認先がOLEH直後に接続を閉じても成功結果を破棄しません。逆接続の要求前に
待受ソケットの起動を待ちます。確認失敗の詳細は `portCheckError` で返し、画面には
実際に確認した待受ポート番号とともに表示します。

`PEERCAST_PORT_CHECK_TEST=ON` で `port_check_test` をビルドできます。
Android端末上で通常実行と `reset`・`blocked`・`invalid` 引数をそれぞれ実行すると、
本物のTCP逆接続とPCPセッション照合を使って、正常応答、応答直後の切断、
逆接続失敗の応答、不正なセッションIDの判定を検証します。


### 設定画面からのSP確認

設定の「SPでポート開放を確認」は、チャンネルに接続せず `startListener` で待受だけを
開始します。ネイティブの `listening` が真になってから、SPのポート変更ページを
WebViewで開きます。SP側の使用ポートを画面に表示された番号に合わせ、確認結果を
更新してください。待受中の表示は外部到達確認の成功を意味しません。
画面終了・バックグラウンド移行・Wi-Fi喪失では待受を停止し、再開は手動操作です。
