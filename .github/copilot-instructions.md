# IntPerInt - Local AI Assistant Project

SwiftUI製のmacOSアプリケーション「IntPerInt」は、ローカルLLM推論とクラウドAI APIを統合したインテリジェントなアシスタントです。

## プロジェクト要件
- [x] SwiftUI macOSアプリ「IntPerInt」
- [x] LLaMA.cppによるローカルLLM推論機能（基盤実装完了）
- [x] OpenAI API統合（基盤実装完了）
- [ ] 将来的なOpenCVマルチモーダル機能（計画中）
- [x] GGUFモデル自動ダウンロード機能

## 技術スタック
- SwiftUI + Combine
- Swift Package Manager
- LLaMA.cpp (Homebrew)
- URLSession for networking

## 完了項目
- [x] プロジェクト構造作成
- [x] SwiftUI基本UI実装
- [x] モデル管理システム
- [x] ダウンロード機能
- [x] 設定画面
- [x] ビルド成功確認
- [x] ドキュメント作成

## 実行方法
```bash
swift build    # ビルド
swift run      # 実行
```

プロジェクトは正常にビルド・実行できる状態です。
