printf "%s\n" "$PATH" | tr ':' '\n'
# IntPerInt - Local AI Assistant

SwiftUI製のmacOSアプリケーションで、ローカルLLM推論とクラウドAI APIを統合したインテリジェントなアシスタントです。

## 機能

### 🚀 AI プロバイダー
- **LLaMA.cpp** - ローカルでGGUFモデルを実行
- **OpenAI GPT** - クラウドベースのGPT API統合

### 🔄 モデル管理
- GGUF形式モデルの自動ダウンロード
- HuggingFace リポジトリからの直接インポート
- 推奨モデル（Llama 2, CodeLlama, Mistral）
- カスタムモデルURL対応

### ⚙️ 設定
- Temperature, Max Tokens, Top-p調整
- カスタムシステムプロンプト
- プロバイダー別設定管理

### 🎯 将来の機能
- OpenCVによるマルチモーダル処理
- 画像・動画解析機能
- FFmpeg統合

## 前提条件

### macOS要件
- macOS 13.0以降
- Xcode 15.0以降（開発する場合）

### LLaMA.cpp（ローカル推論用）
```bash
# Homebrewでインストール
brew install llama.cpp
```

### Swift Package Manager
プロジェクトはSwift Package Managerを使用しています。

## インストール・実行

### 1. リポジトリをクローン
```bash
git clone <repository-url>
cd IntPerInt
```

### 2. ビルドと実行
```bash
# ビルド
swift build

# 実行
swift run
```

### 3. 開発用にXcodeで開く
```bash
swift package generate-xcodeproj
open IntPerInt.xcodeproj
```

## 使用方法

### 初回起動
1. アプリを起動
2. サイドバーから「GGUFモデル管理」を選択
3. 推奨モデルから選択してダウンロード
4. チャット画面でプロバイダーを「LLaMA.cpp (ローカル)」に設定

### OpenAI API使用
1. 設定画面でAPI Keyを入力
2. プロバイダーを「OpenAI GPT」に切り替え

### モデルのカスタマイズ
1. 設定画面でTemperature, Max Tokens, Top-pを調整
2. システムプロンプトをカスタマイズ

## プロジェクト構造

```
IntPerInt/
├── Sources/IntPerInt/
│   ├── App.swift              # メインアプリ構造
│   ├── ContentView.swift      # メインUI
│   ├── Models.swift           # データモデル定義
│   ├── Views.swift            # UI コンポーネント
│   └── Managers.swift         # AI処理管理
├── Tests/IntPerIntTests/
│   └── IntPerIntTests.swift   # テストケース
├── Package.swift              # Swift Package設定
└── README.md                  # このファイル
```

## 技術スタック

- **SwiftUI** - ユーザーインターフェース
- **Combine** - 非同期処理・リアクティブプログラミング
- **LLaMA.cpp** - ローカルLLM推論エンジン
- **URLSession** - ネットワーク通信・ファイルダウンロード
- **FileManager** - ローカルファイル管理

## 開発

### デバッグビルド
```bash
swift build -c debug
```

### リリースビルド
```bash
swift build -c release
```

### テスト実行
```bash
swift test
```

### Xcodeプロジェクト生成
```bash
swift package generate-xcodeproj
```

## トラブルシューティング

### LLaMA.cppライブラリが見つからない場合
```bash
# Homebrewでインストール
brew install llama.cpp

# パスを確認
brew --prefix llama.cpp
```

### モデルダウンロードの問題
- インターネット接続を確認
- 十分なディスク容量があることを確認
- HuggingFaceのモデルURLが正しいことを確認

### ビルドエラーの場合
```bash
# キャッシュをクリア
swift package clean

# 依存関係をリセット
swift package reset
```

## 最終チェックと即応ポイント（実エンジン/インストール済み/送信直前ロード）

以下は、実エンジンのみ・インストール済みのみ・送信直前ロードの最小差分実装が入っている前提での最終確認フローです。

### 動作確認（アプリ内・最短手順）

1) 任意：CLIパスを明示

```bash
export LLAMACPP_CLI=/tmp/llama.cpp/build/bin/llama-cli
```

2) アプリ起動 → モデル選択

- Welcome/モデル一覧に「インストール済み .gguf」のみが表示されること
- 例: tiny-mistral-Q4_K_M.gguf を選択

3) 送信→プリロード→ストリーミング

- 新規チャットで「hello」を送信（⌘⏎）
- コンソール/OSLogに以下が出ること
	- REAL ENGINE LOADED, model path: ...
	- system info: ...
- メッセージが逐次トークン表示される
- Stopで即停止（プロセスterminate相当が走る）

### ワンコマンド検証（CLI単体）

モデル名は環境に合わせて差し替え：

```bash
/tmp/llama.cpp/build/bin/llama-cli \
	-m "$HOME/Library/Application Support/IntPerInt/Models/tiny-mistral-Q4_K_M.gguf" \
	-p "Hello from IntPerInt" \
	-n 16 --temp 0.7 --seed 1 --stop "</s>" --log-verbosity 0
```

→ 先頭にバナー、続いて生成文が出ればOK。

### ありがちなハマりどころ（即応）

- ヘルプ画面が出る：引数違いの可能性。-p（または --prompt）と -n を使う。--max-tokens はビルドにより非対応。
- プリロードで失敗：LLAMACPP_CLI が未検出 or 実行権限なし。chmod +x、export LLAMACPP_CLI=... を確認。
- モデルが一覧に出ない：拡張子/配置。~/Library/Application Support/IntPerInt/Models/*.gguf 直下か要確認。
- 停止が遅い：内部でプロセスterminateを呼ぶ実装。再現ログがあれば調整可能。

### 実装ポイント（要旨）

- LlamaCppEngine
	- CLI検出順: $LLAMACPP_CLI → /opt/homebrew/... → /usr/local/... → /tmp/.../llama-cli → /tmp/.../main
	- load(): -m <model> -p test -n 1 [--log-verbosity 0] でプリロード、成功時 REAL ENGINE LOADED ログ
	- generate(): --stop 複数対応、--seed 対応、STDOUTを逐次読みでトークン表示。キャンセルで即terminate。
- ModelManager
	- 送信直前のみ prepareEngineIfNeeded() でロード。installed/valid のみに絞ったPicker。
	- start/finish/cancel ログを出力。

## ライセンス

MIT License

## 貢献

プルリクエストやIssueを歓迎します。

## 更新履歴

### v1.0.0 (初回リリース)
- SwiftUI基本UI実装
- LLaMA.cpp統合準備
- OpenAI API統合準備
- GGUF モデル自動ダウンロード機能
- 基本設定画面実装
