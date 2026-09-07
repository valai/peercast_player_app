# PeerCast App

FlutterによるiOS / Android向けPeerCastクライアント。

## 現在の状態

YP・掲示板と、PeerCast YTコアによる直接視聴・リレーを実装した開発版です。

- 初回のみ既定のYPを登録。YPの追加・編集・削除・有効切替を端末に保存。
- 複数YPのチャンネル一覧、検索、お気に入り、更新。YP単位で取得失敗を表示。
- チャンネルの閲覧履歴を最大100件保存。
- JPNKN・したらばを判別し、WebViewで板またはスレッドを表示。標準フォームを利用可能。
- 選択したスレッドURLをチャンネル別に保存。縦・横画面での分割表示。
- FLVの直接視聴、リレー開始・停止、実接続数・送信量・到達性の表示。
- Wi-Fi限定、最大下流数、待受ポートを通信に適用。バックグラウンド・画面終了時は停止。

ポート未開放の環境で複数チャンネルの映像表示・ローカル下流への転送・バックグラウンド停止を確認しています。外部からのリレー着信、30分連続視聴、実機・iOS・掲示板投稿の検証は未実施です。
上流ソースは固定リビジョンで取得し、Android/iOS共通のC++ライブラリとして組み込みます。

- 開発・実行方法: [開発環境](docs/DEVELOPMENT.md)
- 確定した機能仕様: [実装計画](docs/IMPLEMENTATION_PLAN.md)
- コア統合・検証結果: [ネイティブコア](docs/NATIVE_CORE.md)
- 使用バージョン: [toolchain.json](toolchain.json)

## Windowsで実行

このフォルダーをPowerShellで開き、次を実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\prepare-native.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flutter.ps1 pub get
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flutter.ps1 run
```

`run` にはUSBデバッグを許可したAndroid端末、または起動済みAndroidエミュレーターが必要です。
実行ポリシーの指定はそのPowerShellプロセスだけに作用します。

## 検証

```powershell
.\scripts\flutter.ps1 analyze
.\scripts\flutter.ps1 test
.\scripts\flutter.ps1 build apk --debug
```

APK: `build/app/outputs/flutter-apk/app-debug.apk`

## 通信

既定のYPからチャンネル一覧を取得します。
2026-09-07に両公式サイトと実際のUTF-8・19フィールドの応答を確認しました。
HTTP例外は一部の既定YP、対応掲示板、端末内接続だけに限定しています。
追加YP・その他コンタクト先はHTTPSを推奨します。任意のHTTPサイトのWebView表示は保証しません。
