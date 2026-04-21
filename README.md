# Minimal Local LLM Chat

Ruby バックエンドと React フロントエンドで、Ollama の `gemma3:1b` と会話する最小構成です。

## 構成

- `backend`: Sinatra API
- `frontend`: Vite + React UI

## 前提

- Ruby 3.x
- Bundler
- Node.js 18 以上
- Ollama

## 1. Ollama を起動してモデルを取得

```bash
ollama serve
```

別ターミナルで:

```bash
ollama pull gemma3:1b
```

## 2. バックエンドを起動

```bash
cd backend
bundle install
bundle exec ruby app.rb
```

`http://localhost:4567/health` が `{"status":"ok"}` を返せば起動しています。

## 3. フロントエンドを起動

```bash
cd frontend
npm install
npm run dev
```

ブラウザで `http://localhost:5173` を開きます。

## API

`POST /chat`

リクエスト例:

```json
{
  "messages": [
    { "role": "user", "content": "こんにちは" }
  ]
}
```

レスポンス例:

```json
{
  "message": "こんにちは。どうしましたか？"
}
```

## 補足

- モデル名を変えたい場合は `backend/app.rb` の `model: "gemma3:1b"` を変更してください。
- この実装は会話履歴をフロントエンドの state にだけ持つ最小構成です。DB 保存、ストリーミング、認証は入れていません。
