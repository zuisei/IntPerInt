完成しておりません。ご勘弁を
ーーーーーー実装されてる機能一覧ーーーーーー



## アプリ（SwiftUI/macOS）

- 会話UIと設定画面、モデル管理ガイド
  - ローカルGGUFの手動配置を前提（分割GGUF *.gguf.partN 検出と案内）
  - 以前の「アプリ内モデルダウンロードUI」は撤去
- 会話の永続化
  - `ConversationStore` による保存/復元
- エンジン切替
  - ローカル組み込み: llama.cpp ライブラリ（ObjCブリッジ `LLamaCppWrapper.h/.mm`、`LlamaCppLibEngine`）
  - 外部ストリーミング: UDSヘルパー経由（トグルで選択）
- 生成体験
  - トークン逐次ストリーミング表示（UIデバウンスで負荷軽減）
  - 生成キャンセル操作に対応
- OpenAI API統合（基盤）
  - プロバイダ切替の土台あり（完全オフライン運用時は未使用）

## UDSヘルパー（C++ / Unix Domain Socket）

- ソケット/プロトコル
  - intperint.sock で JSON Lines 通信（1行1 JSON）
- LLMストリーミング
  - `start_chat` で外部コマンド起動→`{"op":"token"}` を逐次送出→`{"op":"done"}` まで
  - `cancel` で実行中プロセスをPID管理して停止可能
- 画像/動画生成
  - `generate_image`: Diffusers(MPS) または stable-diffusion.cpp コマンドテンプレ対応
  - `submit_video`: AnimateDiffベースの簡易動画（img2imgフレーム→ffmpeg結合）
  - `job_status`: 進捗/結果参照
- 出力/ログ
  - `~/Library/Application Support/IntPerInt/outputs/<jobid>/` に画像/動画/ログ/メタ出力
- 設定（`config.json`）
  - `command_templates` と `workdir_base`、モデル/バイナリのパス解決（テンプレ/フォールバック）
  - llama.cpp/SD/AnimateDiff 用テンプレに差し替え可能

## スクリプト/サービス層

- 画像/動画スクリプト
  - `run_sd_diffusers.py`（Diffusers + MPS）
  - `animate_diff_run.py`（フレーム生成→ffmpeg）
- UDSクライアント（アプリ側）
  - `Services/UDSClient.swift` に統合（単発送信・ストリーム受信）
- 動作確認
  - uds_chat_test.py（ストリーミング検証用）

## テスト/ビルド

- アプリ側テスト
  - IntPerIntTests（永続化/ストリーミングの基本テスト）
- ヘルパービルド
  - CMake + Clang（Apple Silicon）、起動ログ `helper_run.log` 出力

補足
- 現状は「ローカルGGUFの手動配置 + UDSストリーミング or ライブラリ直実行」の二本立て。UDS経由はトークンストリームとキャンセルが安定動作。OpenAIは基盤のみ有効。