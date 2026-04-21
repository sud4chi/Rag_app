# Minimal Local LLM Chat

Ruby バックエンドと React フロントエンドで、Ollama の `gemma3:1b` と会話する最小構成です。ローカル開発と本番デプロイを同じコードで切り替えやすいように、接続先は環境変数ベースにしています。

## 構成

- `backend`: Sinatra API
- `frontend`: Vite + React UI
- `frontend` は開発時に Vite proxy 経由で `backend` に接続
- 本番では `frontend` のビルド成果物を静的配信し、`/api` を `backend` にリバースプロキシする想定

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

`http://localhost:4567/api/health` が `{"status":"ok","model":"gemma3:1b"}` を返せば起動しています。

## 3. フロントエンドを起動

```bash
cd frontend
npm install
npm run dev
```

ブラウザで `http://localhost:5173` を開きます。

## 環境変数

### backend

```bash
PORT=4567
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_MODEL=gemma3:1b
ALLOWED_ORIGINS=http://localhost:5173
```

### frontend

```bash
VITE_API_BASE_URL=
```

- ローカル開発では空のままで構いません。Vite の `/api` プロキシが Ruby に転送します。
- 本番でフロントと API を別ドメインに分けるなら `VITE_API_BASE_URL=https://api.example.com` のように設定します。

## API

`POST /api/chat`

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

## ローカル開発

1. ターミナル1で `ollama serve`
2. ターミナル2で `cd backend && bundle install && bundle exec ruby app.rb`
3. ターミナル3で `cd frontend && npm install && npm run dev`

フロントは `/api/chat` を叩きますが、開発時は Vite が自動で `http://localhost:4567` に転送します。フロントコードに `localhost:4567` を直書きしていないので、そのまま本番に移せます。

## 本番デプロイの考え方

- `frontend` は `npm run build` で静的ファイルにする
- `backend` は `bundle exec ruby app.rb` か `puma` で常駐
- `ollama serve` も同じ EC2 内で常駐
- Nginx などで:
  - `/` を `frontend/dist` に向ける
  - `/api` を `backend` にプロキシする
- `ALLOWED_ORIGINS` は本番のフロント URL に変更する
- `OLLAMA_BASE_URL` は同一ホストなら `http://localhost:11434` のままでよい

Nginx 例:

```nginx
server {
  listen 80;
  server_name _;

  root /var/www/local-llm-chat/frontend/dist;
  index index.html;

  location /api/ {
    proxy_pass http://127.0.0.1:4567;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }

  location / {
    try_files $uri /index.html;
  }
}
```

## 補足

- モデル名を変えたい場合は `OLLAMA_MODEL` を変更してください。
- この実装は会話履歴をフロントエンドの state にだけ持つ最小構成です。DB 保存、ストリーミング、認証は入れていません。
