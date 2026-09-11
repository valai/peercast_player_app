# 第三者ソースとライセンス

本リポジトリ独自のコード・文書は GPL-3.0-or-later で提供します。
第三者のコード・素材にはそれぞれのライセンスが適用され、既存の著作権表示は維持します。

## PeerCast YT

- 上流: https://github.com/plonk/peercast-yt
- リビジョン: `b60f176317406e79a5468ba80da8be1d83bb6126`
- コアの表示: GPL-2.0-or-later（例: `core/common/sys.h`）。本プロジェクトはその「以降のバージョン」の選択肢を利用して GPLv3 と組み合わせます。
- 元のGPLv2原文: `assets/licenses/peercast-gpl.txt`
- 移植変更: `native/mobile/` と `docs/NATIVE_CORE.md`。本アプリの移植変更であり、上流が提供・保証する変更ではありません。
- 上流同梱の第三者コンポーネントについては、上流の `licenses/` および各ファイルの表示も参照してください。

## BoringSSL

- 上流: https://boringssl.googlesource.com/boringssl
- リビジョン: `4a92579453b35319e2707eab68a0b7d1f8d5d053`
- ライセンス原文: `assets/licenses/boringssl.txt`（上流 `LICENSE`）。ファイル単位の表示も維持してください。

## Flutter・Dart・再生バックエンド等

- 依存バージョン: `pubspec.lock`、`ios/Podfile.lock`、`toolchain.json`
- Dartパッケージのライセンス: アプリ設定のライセンス画面、および各パッケージの原文。
- AndroidはMedia3、iOSはmedia_kitを使用します。ネイティブ同梱物の条件は、将来バイナリ配布を行う際に配布対象ごとに確認してください。

この一覧はソースリポジトリ公開用の案内です。バイナリ配布向けの網羅的なライセンス監査・対応ソースパッケージ作成を完了したという意味ではありません。
