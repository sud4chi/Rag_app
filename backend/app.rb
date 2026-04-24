require "fileutils"
require "json"
require "net/http"
require "sqlite3"
require "sinatra"
require "time"

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 4567)
set :server, :webrick

helpers do
  def allowed_origins
    ENV.fetch("ALLOWED_ORIGINS", "http://localhost:5173")
      .split(",")
      .map(&:strip)
      .reject(&:empty?)
  end

  def request_origin
    request.env["HTTP_ORIGIN"]
  end

  def cors_origin
    origin = request_origin
    return "*" if allowed_origins.include?("*")
    return origin if origin && allowed_origins.include?(origin)

    allowed_origins.first
  end

  def ollama_uri
    URI("#{ENV.fetch("OLLAMA_BASE_URL", "http://localhost:11434")}/api/chat")
  end

  def ollama_model
    ENV.fetch("OLLAMA_MODEL", "gemma3:1b")
  end

  def db_path
    ENV.fetch("DATABASE_URL", File.expand_path("db/app.sqlite3", __dir__))
  end

  def db
    settings.db
  end

  def parse_json_body
    request_body = request.body.read
    request_body.empty? ? {} : JSON.parse(request_body)
  end

  def now_iso8601
    Time.now.utc.iso8601
  end

  def serialize_prompt(row)
    return nil unless row

    {
      id: row["id"],
      title: row["title"],
      body: row["body"],
      tag: row["tag"],
      created_at: row["created_at"],
      updated_at: row["updated_at"]
    }
  end

  def validate_prompt_payload(payload)
    title = payload["title"]&.strip
    body = payload["body"]&.strip

    halt 400, { error: "title は必須です。" }.to_json if title.nil? || title.empty?
    halt 400, { error: "body は必須です。" }.to_json if body.nil? || body.empty?
  end
end

configure do
  db_file = ENV.fetch("DATABASE_URL", File.expand_path("db/app.sqlite3", __dir__))
  FileUtils.mkdir_p(File.dirname(db_file))

  connection = SQLite3::Database.new(db_file)
  connection.results_as_hash = true
  connection.execute_batch(<<~SQL)
    CREATE TABLE IF NOT EXISTS prompts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      tag TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  SQL

  set :db, connection
end

before do
  headers(
    "Access-Control-Allow-Origin" => cors_origin,
    "Access-Control-Allow-Methods" => "GET,POST,PUT,DELETE,OPTIONS",
    "Access-Control-Allow-Headers" => "Content-Type",
    "Vary" => "Origin"
  )
  content_type :json if request.path_info.start_with?("/api/")
end

options "*" do
  200
end

get "/health" do
  redirect to("/api/health"), 307
end

get "/api/health" do
  {
    status: "ok",
    model: ollama_model
  }.to_json
end

post "/chat" do
  redirect to("/api/chat"), 307
end

post "/api/chat" do
  payload = parse_json_body
  messages = payload["messages"] || []

  uri = ollama_uri
  ollama_request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  ollama_request.body = {
    model: ollama_model,
    stream: false,
    messages: messages
  }.to_json

  response = Net::HTTP.start(uri.hostname, uri.port) do |http|
    http.request(ollama_request)
  end

  halt response.code.to_i, response.body unless response.is_a?(Net::HTTPSuccess)

  data = JSON.parse(response.body)
  {
    message: data.dig("message", "content") || ""
  }.to_json
rescue Errno::ECONNREFUSED
  status 503
  {
    error: "Ollama API に接続できません。`ollama serve` が起動しているか確認してください。"
  }.to_json
rescue JSON::ParserError
  status 400
  { error: "JSON の形式が不正です。" }.to_json
end

get "/api/prompts" do
  rows = db.execute("SELECT * FROM prompts ORDER BY datetime(updated_at) DESC, id DESC")
  { prompts: rows.map { |row| serialize_prompt(row) } }.to_json
end

get "/api/prompts/:id" do
  row = db.get_first_row("SELECT * FROM prompts WHERE id = ?", params[:id])
  halt 404, { error: "Prompt が見つかりません。" }.to_json unless row

  serialize_prompt(row).to_json
end

post "/api/prompts" do
  payload = parse_json_body
  validate_prompt_payload(payload)

  timestamp = now_iso8601
  tag = payload["tag"]&.strip

  db.execute(
    "INSERT INTO prompts (title, body, tag, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
    [payload["title"].strip, payload["body"].strip, tag.nil? || tag.empty? ? nil : tag, timestamp, timestamp]
  )

  status 201
  row = db.get_first_row("SELECT * FROM prompts WHERE id = ?", db.last_insert_row_id)
  serialize_prompt(row).to_json
rescue JSON::ParserError
  status 400
  { error: "JSON の形式が不正です。" }.to_json
end

put "/api/prompts/:id" do
  existing = db.get_first_row("SELECT * FROM prompts WHERE id = ?", params[:id])
  halt 404, { error: "Prompt が見つかりません。" }.to_json unless existing

  payload = parse_json_body
  validate_prompt_payload(payload)

  timestamp = now_iso8601
  tag = payload["tag"]&.strip

  db.execute(
    "UPDATE prompts SET title = ?, body = ?, tag = ?, updated_at = ? WHERE id = ?",
    [payload["title"].strip, payload["body"].strip, tag.nil? || tag.empty? ? nil : tag, timestamp, params[:id]]
  )

  row = db.get_first_row("SELECT * FROM prompts WHERE id = ?", params[:id])
  serialize_prompt(row).to_json
rescue JSON::ParserError
  status 400
  { error: "JSON の形式が不正です。" }.to_json
end

delete "/api/prompts/:id" do
  existing = db.get_first_row("SELECT * FROM prompts WHERE id = ?", params[:id])
  halt 404, { error: "Prompt が見つかりません。" }.to_json unless existing

  db.execute("DELETE FROM prompts WHERE id = ?", params[:id])
  status 204
  body ""
end
