# karukan-macos

macOS向けKarukan日本語入力(InputMethodKit + Swift)。

## アーキテクチャ

サーバー・クライアント構成です。IMEの状態機械・ローマ字変換・かな漢字変換はすべて
Rust側(`karukan-im`)にあり、Swift側はInputMethodKitとの橋渡しに徹します。

```
┌───────────────────────────────┐                            ┌─────────────────────────────┐
│ KarukanIME (Swift)            │  JSON-RPC 2.0 (改行区切り)  │ karukan-imserver (Rust)     │
│ ・IMKServer / InputController │ ◀────────────────────────▶ │ ・InputMethodEngine         │
│ ・NSEvent → XKB keysym変換    │    stdin/stdout パイプ      │ ・ローマ字変換・状態機械    │
│ ・preedit / 候補ウィンドウ描画 │                            │ ・llama.cpp推論・辞書・学習 │
│ ・子プロセス管理・自動再起動   │                            │                             │
└───────────────────────────────┘                            └─────────────────────────────┘
        どちらも Karukan.app バンドル内 (Contents/MacOS/)
```

- プロトコル定義: `karukan-im/core/src/server/protocol.rs`(Rust側が正)と
  `Sources/KarukanIME/EngineProtocol.swift`(Swift側ミラー)
- キーイベントはfcitx5版と同じXKB keysym表現に変換して送る
  (`Sources/KarukanIME/KeyCodeMap.swift`)
- エンジンプロセスはクラッシュ時に指数バックオフで自動再起動、
  スリープ復帰時にも再起動(macOSがスリープ中にパイプを破棄するため)

## インストール

### 初回インストール

```bash
cd karukan-im/macos

# ビルド + .appバンドル組み立て + ~/Library/Input Methods へインストール
make install
```

その後、以下の手順で利用できます:

1. macOSからログアウトし、再ログイン(macOSが新しいIMEを認識するために必要)
2. 「システム設定」>「キーボード」>「入力ソース」を編集 >「+」ボタン>「日本語」> **Karukan** を追加
3. メニューバーの入力メニューからKarukanを選択

> **Note:** `make install` 実行時に変換モデル(設定の `[models]` に定義された全モデル)を
> Hugging Faceからダウンロードしてキャッシュ(`~/.cache/huggingface/`)に配置します。
> パス文字列で指定したローカルモデルはダウンロードせず、ファイルがあるかだけ確認します。
> オフラインなどでダウンロードに失敗した場合は、IMEの起動時にバックグラウンドで
> ダウンロードされます。その間もかな入力と辞書変換はそのまま使え、モデルの読み込みが
> 完了すると自動でモデル変換が有効になります。

### 開発版の更新(2回目以降)

ログアウトは不要で、この2コマンドだけで反映されます:

```bash
make install
killall KarukanIME  # 次にテキストフィールドへフォーカスした時に自動で再起動
```

ただし**コード以外のメタデータ**(メニューアイコン、入力モード名、Info.plistの
入力モード定義)はmacOS側にキャッシュされるため、`killall KarukanIME` では反映され
ないことがあります。その場合は次のいずれかで反映されます:

```bash
# 入力メニューのアイコン・名前のキャッシュを更新(エージェントは自動再起動)
killall TextInputMenuAgent
```

- それでも反映されない場合: システム設定 → 入力ソースからKarukanを削除 → 再追加
- 最終手段: ログアウト → ログイン

### テスト

```bash
# Swift + Rustサーバー統合テスト
make test
```

## システム辞書のインストール

モデル推論だけでは語彙が限られるため、システム辞書の併用を強く推奨します。
`make install` 実行時に、辞書が未インストールであればGitHubリリースのビルド済み辞書
(`dict.tgz`)を自動でダウンロードして配置します。既に
`~/Library/Application Support/com.karukan.karukan-im/dict.bin` がある場合は
何もしません(自前ビルドの辞書が上書きされることはありません)。

手動でインストールする場合:

```bash
curl -LO https://github.com/togatoga/karukan/releases/latest/download/dict.tgz
tar xzf dict.tgz
mkdir -p ~/Library/"Application Support"/com.karukan.karukan-im
cp dict.bin ~/Library/"Application Support"/com.karukan.karukan-im/
killall KarukanIME  # 起動中の場合は再起動して反映
```

辞書を自分でビルドする場合は [karukan-cli の README](../../karukan-cli/README.md) を参照してください。

## キー操作

[docs/key-bindings.md](../../docs/key-bindings.md) を参照してください（共通キーバインドに加えて、JISかな・英数キーや右⌘単独タップなどのmacOS固有キーをまとめています）。

## 設定・データファイル

`directories`クレートのmacOS既定パスを使用します:

- 設定: `~/Library/Application Support/com.karukan.karukan-im/config.toml`
- システム辞書: `~/Library/Application Support/com.karukan.karukan-im/dict.bin`
- ユーザー辞書: `~/Library/Application Support/com.karukan.karukan-im/user_dicts/`
- 学習データ: `~/Library/Application Support/com.karukan.karukan-im/learning.tsv`

設定項目は [docs/configuration.md](../../docs/configuration.md) を、辞書は [docs/dictionary.md](../../docs/dictionary.md) を参照してください。

## デバッグ

- ログ: `~/Library/Logs/KarukanIME/karukan-ime.log`(Swift側NSLogとRust側tracingの両方)
- サーバー単体デバッグ: JSON-RPCを直接流せます

  ```bash
  cargo run -p karukan-im --bin karukan-imserver
  {"jsonrpc":"2.0","id":1,"method":"process_key","params":{"keysym":107}}
  ```

- バンドルを組み立てずに開発中のサーバーを使う: `KARUKAN_IMSERVER=/path/to/karukan-imserver`

### 入力が反映されない場合の診断ログ

候補は更新されるのに入力欄へ文字が出ない場合、次の設定で診断ログを有効にします。
設定はKarukanの起動時に読み取ります。再起動前に未確定の文字を確定してください。

```bash
defaults write dev.togatoga.inputmethod.Karukan InputDiagnosticsEnabled -bool true
killall KarukanIME
```

保存先は `~/Library/Logs/KarukanIME/input-diagnostics.log`（JSON Lines）です。
1ファイル8 MiB、過去3ファイル（`.1`〜`.3`）まで残し、所有者だけが読み書きできます。
書き込みは別キューで行い、書き込みに失敗した場合は診断ログを停止します。

記録するのは時刻、実行・セッションID、入力イベントの連番、接続先と前面アプリ、
エンジンの応答種別、文字数、文字挿入などのIPCの開始・終了・所要時間です。
スキーマ2ではイベント受信を除外判定の前に記録し、⌘ショートカット等の除外理由、
イベントとOSの修飾キー状態、選択中の入力ソース、Secure Inputの有効状態も記録します。
OSのキー押下の累積回数とIME受信回数は0.5秒間隔で照合し、変化したときだけ記録します。
この集計にイベントタップや追加のアクセシビリティ権限は使いません。
入力文字、キーコード、変換候補、周辺テキスト、ウィンドウタイトルは記録しません。
スキーマ3では、`handle` の開始・終了と空イベント、認識イベントの照会、
入力モード変更、`activateServer` の開始・終了も記録します。
コールバック入口では入力先や候補パネルへの追加照会を行いません。
イベントの起動後時刻と、専用試験アプリが付与した識別子だけを保存し、
試験アプリの記録とIMEの受信記録を照合できます。通常のキーには識別子を保存しません。
未確定範囲の照会だけを追加IPCとして、未確定文字の先頭、以後最大1秒に1回、確定直後に行います。
この設定は既存の `karukan-ime.log` やRust側のログレベルには影響しません。

`clientCallEnd` は呼び出しが戻った記録であり、画面への反映成功を保証しません。
`markedRange` の `rangeAvailable: false` も、アプリのAPI未対応の場合があるため障害の断定には使いません。
未確定文字がない状態での空の未確定文字送信は省略し、`redundantPreeditClearSkipped` として記録します。
これにより、入力先の切り替え中に不要な同期IPCが別セッションの開始と重なる経路を減らします。
再発したら普段どおりアプリを切り替えて復旧し、発生した時刻とアプリ名を手掛かりに前後を比較します。

専用の入力クライアントと比較する手順は
[ConnectionProbe](Diagnostics/ConnectionProbe/README.md) を参照してください。

診断を終えるときは無効にしてKarukanを再起動します。ログファイルは残ります。

```bash
defaults write dev.togatoga.inputmethod.Karukan InputDiagnosticsEnabled -bool false
killall KarukanIME
```

## 既知の制約

- ローマ字入力のみ対応(かな入力レイアウトは未対応)
- 候補ウィンドウはマウス操作不可(数字キー・矢印キーで選択)

## 参考プロジェクト

- [mac-akaza](https://github.com/akaza-im/mac-akaza)
