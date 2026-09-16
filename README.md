# ぺかわん

FlutterによるiOS / Android向けPeerCastクライアント。

### iOSシミュレーターの音声制限

`media_kit_libs_ios_video 1.1.4` に同梱されたlibmpvは、実機用では
`-Daudiounit=enabled`、シミュレーター用では `-Daudiounit=disabled` で
ビルドされています。音声セッションを有効化するだけでは、シミュレーターの
`Could not open/initialize audio device -> no sound.` は解消しません。
シミュレーターではネイティブ側の `targetEnvironment(simulator)` 判定でのみ
無音出力を選択し、画面に注意を表示して映像再生を継続します。
実機では音声を無効化しません。音声の確認は実機で行ってください。
この判定はSwiftを含むため、変更後はホットリロードだけでなくiOSアプリの
再ビルド・再インストールが必要です。

## 現在の状態

YP・掲示板と、PeerCast YTコアによる直接視聴・リレーを実装した開発版です。

- 初回のみ既定のYPを登録。YPの追加・編集・削除・有効切替を端末に保存。
- 複数YPのチャンネル一覧、検索、お気に入り、更新。YP単位で取得失敗を表示。
- チャンネルの閲覧履歴を最大100件保存。
- 対応する掲示板のスレッドをアプリ内で表示。新着へのオートスクロール、15/30/60/120秒のオートリロード（OFF可）、名前・メール・本文の書き込みに対応。板の一覧・その他のコンタクトはWebViewで表示。
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
HTTP例外は一部の既定YP、対応掲示板、端末内接続だけに限定しています。
HTTPで提供される一部の対応掲示板では、対象パスのHTTPS指定をHTTPへ補正します。
追加YP・その他コンタクト先はHTTPSを推奨します。任意のHTTPサイトのWebView表示は保証しません。

## ソース公開・配布前の確認

[公開前チェック](docs/PUBLIC_RELEASE.md)を参照してください。
GitHubをPublicへ変更する前に、匿名化済み履歴への置き換えとGitHub側の公開対象を確認してください。

## ライセンス

本リポジトリ独自のコード・文書は **GNU GPL v3.0以降（GPL-3.0-or-later）** で提供します。
再配布・変更は同ライセンスに従って行えます。無保証です。
全文は[LICENSE](LICENSE)、第三者ソースの適用条件・帰属は[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)を参照してください。
第三者のコード・素材については、それぞれのライセンスと著作権表示を維持します。
