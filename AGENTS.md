# このリポジトリでの作業指示

## Windows実行環境の既知の初期化エラー

2026-09-09、この環境では通常のサンドボックス実行がコマンドの開始前に失敗した。ユーザーから毎回発生すると報告されている。次回以降は本項を先に読み、同じ原因調査を繰り返さず、以下の確認済み手順を使う。

対象エラー:

- exec_command: Failed to create unified exec process
- Rejected("... helper_unknown_error: setup refresh had errors")
- node_repl: windows sandbox failed: helper_unknown_error: setup refresh had errors

これはアプリのビルドエラーではなく、実行環境の初期化失敗。根本原因の特定や環境自体の恒久修復は未実施。

### 確認済みの回避手順

このWindows環境で exec_command を使う場合、現在の権限ポリシーで許可されていれば、最初から sandbox_permissions: "require_escalated" を指定し、justification に依頼された作業に必要な具体的な理由を記載する。通常実行を何度も試してから切り替える必要はない。

今回、この方法でファイルの読み書き、Gitの読み取り、Dartの整形、Flutterの静的解析・テストが成功した。通常実行の login: false への変更と node_repl への切り替えは同じ初期化エラーになったため、このエラーに対しては再試行しない。代替ツールの一覧を広範囲に検索することも不要。

これはツールが提供する正式な承認付き実行経路を使う手順であり、承認の省略や権限設定の変更を指示するものではない。各コマンドの権限審査はその都度適用される。上位の指示で昇格実行が禁止されている場合は従う。自動承認レビューで拒否された場合、別のツールで拒否を迂回しない。拒否理由と未完了の作業をユーザーに伝える。

昇格実行でも失敗した場合は、その新しいエラーを確認して対処する。この記録だけから成功したと判断しない。別OS・別環境で同じ回避策が必要とは限らない。

### 使用量を抑える進め方

- 初期化エラーの確認のためだけに、既知の失敗手順を繰り返さない。
- ファイル検索は rg / rg --files を優先し、関連箇所だけ読む。
- 独立した読み取りはまとめ、巨大なファイル全文や全ツールの説明を出力しない。
- 変更に必要な検証が成功したら、新しい変更や懸念がない限り繰り返さない。
- 本ファイルの読み取り自体が同じ初期化エラーで失敗する場合も、許可されている承認付き実行経路で読む。

## Flutterの実行方法

Flutter/Dartは通常のPATHでは見つからなかった。既存の環境設定スクリプトを使う。

- 静的解析: ./scripts/flutter.ps1 analyze
- テスト: ./scripts/flutter.ps1 test
- 整形: & C:/develop/sdks/flutter/bin/dart.bat format <変更したDartファイル>

scripts/flutter.ps1 は scripts/dev-env.ps1 を読み込み、Flutter、Java、Android SDKの環境を設定する。SDKのバージョンは toolchain.json を参照。パスが存在しない場合はスクリプトの設定を確認し、SDKを勝手に再インストールしない。
