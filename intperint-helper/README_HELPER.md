# IntPerInt Helper (UDS, real engine spawn)

このヘルパーは /tmp/intperint.sock の Unix Domain Socket で JSON (改行終端) を受け取り、構成されたコマンドテンプレートに従って実エンジン (stable-diffusion.cpp / diffusers / AnimateDiff / llama.cpp) をサブプロセスとして起動します。

- ソケット: /tmp/intperint.sock
- 出力: ~/Library/Application Support/IntPerInt/outputs/<jobid>/
- 設定: config.json (config.example.json をコピーして編集)
- ビルド: CMake + Clang (Apple Silicon)

## ビルド

```bash
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
cmake --build . -j
```

生成物: build/intperint_helper

## 起動

```bash
rm -f /tmp/intperint.sock
./intperint_helper
```

## プロトコル (JSON Lines)
- クライアント → サーバ: 1 行 1 JSON、改行で終端
- サーバ → クライアント: 同上

リクエスト例:
```json
{"op":"generate_image","prompt":"a cat","negative_prompt":"","nsfw_ok":false,"options":{"steps":20,"w":768,"h":768}}
```

レスポンス例:
```json
{"status":"ok","jobid":"20250821-abc123","image":"/Users/.../outputs/20250821-abc123/image_0001.png","meta":{"engine":"sdxl"}}
```

### LLM ストリーミング チャット

リクエスト:
```json
{"op":"start_chat","model":"llm_20b","prompt":"Hello","tokens":256,"stream":true,"jobid":"abcd1234"}
```

サーバ → クライアントの逐次イベント:
```json
{"op":"chat_started","jobid":"abcd1234"}
{"op":"token","jobid":"abcd1234","data":"Hello"}
{"op":"token","jobid":"abcd1234","data":" world"}
...
{"op":"done","jobid":"abcd1234","exit":0}
```

キャンセル:
```json
{"op":"cancel","jobid":"abcd1234"}
```
応答:
```json
{"status":"ok","jobid":"abcd1234"}
```

## 設定 (config.json)
- command_templates: SD/VIDEO/LLM のテンプレ置換
- paths: モデルや作業ベース
- concurrency: 同時実行数の上限

config.example.json を編集して config.json として設置してください。

## テスト

```bash
python3 tests/uds_test.py
```

問題があれば `~/Library/Application Support/IntPerInt/outputs/<jobid>/log.txt` を確認します。

> 注意: デフォルトのテンプレはダミーでファイルだけ作成します。実行環境に合わせて run_sd_diffusers.py / animate_diff_run.py へのパスを設定してください。
