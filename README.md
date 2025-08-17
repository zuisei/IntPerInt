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
