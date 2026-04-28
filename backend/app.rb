require "json"
require "net/http"
require "sqlite3"
require "sinatra"
require "time"
require 'dotenv/load'
require "natto"

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 4567)
set :server, :webrick

def ensure_sqlite_file!(path, label)
  raise "#{label} が見つかりません: #{path}" unless File.file?(path)
end

def ensure_table_exists!(connection, table_name, label)
  row = connection.get_first_row("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [table_name])
  raise "#{label} に #{table_name} テーブルがありません。" unless row
end

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
    ENV.fetch("DATABASE_URL", File.expand_path("db/prompt.db", __dir__))
  end

  def db
    settings.db
  end

  def wnjpn_db_path
    ENV.fetch("WNJPN_DATABASE_URL", File.expand_path("db/wnjpn.db", __dir__))
  end

  def wnjpn_db
    settings.wnjpn_db
  end

  def parse_json_body
    request_body = request.body.read
    request_body.empty? ? {} : JSON.parse(request_body)
  end

  def find_prompt(id)
    return nil if id.nil? || id.to_s.strip.empty?

    db.get_first_row("SELECT * FROM prompts WHERE id = ?", id)
  end

  def latest_user_message(messages)
    messages.reverse.find { |message| message["role"] == "user" || message[:role] == "user" }
  end

  def synonym_candidates(lemma)
    rows = wnjpn_db.execute(<<~SQL, [lemma])
      SELECT DISTINCT w2.lemma
      FROM word w1
      JOIN sense s1
        ON w1.wordid = s1.wordid
       AND s1.lang = 'jpn'
      JOIN sense s2
        ON s1.synset = s2.synset
       AND s2.lang = 'jpn'
      JOIN word w2
        ON s2.wordid = w2.wordid
       AND w2.lang = 'jpn'
      WHERE w1.lemma = ?
        AND w1.lang = 'jpn'
        AND w2.lemma != w1.lemma
      ORDER BY w2.lemma COLLATE NOCASE ASC
    SQL

    rows.map { |row| row["lemma"] }
  end

  def replaceable_node?(surface, features)
    return false if surface.nil? || surface.empty?

    pos = features[0]
    subpos = features[1]
    return false unless %w[名詞 動詞 形容詞 副詞].include?(pos)
    return false if subpos == "非自立"

    true
  end

  def base_form(surface, features)
    lemma = features[6]
    return surface if lemma.nil? || lemma.empty? || lemma == "*"

    lemma
  end

  def synonymize_text(text)
    output = []

    settings.mecab.parse(text.to_s) do |node|
      surface = node.surface.to_s
      next if surface.empty?

      features = node.feature.to_s.split(",")
      unless replaceable_node?(surface, features)
        output << surface
        next
      end

      lemma = base_form(surface, features)
      candidates = synonym_candidates(lemma)

      output << (candidates.empty? ? surface : candidates.sample(random: settings.random))
    end

    output.join
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
  db_file = ENV.fetch("DATABASE_URL", File.expand_path("db/prompt.db", __dir__))
  ensure_sqlite_file!(db_file, "プロンプトDB")

  connection = SQLite3::Database.new(db_file)
  connection.results_as_hash = true
  ensure_table_exists!(connection, "prompts", "プロンプトDB")

  set :db, connection
  set :random, Random.new

  wnjpn_file = ENV.fetch("WNJPN_DATABASE_URL", File.expand_path("db/wnjpn.db", __dir__))
  ensure_sqlite_file!(wnjpn_file, "類義語DB")

  wnjpn_connection = SQLite3::Database.new(wnjpn_file)
  wnjpn_connection.results_as_hash = true
  ensure_table_exists!(wnjpn_connection, "word", "類義語DB")
  ensure_table_exists!(wnjpn_connection, "sense", "類義語DB")
  set :wnjpn_db, wnjpn_connection
  set :mecab, Natto::MeCab.new
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
  prompt = find_prompt(payload["prompt_id"])
  user_message = latest_user_message(messages)

  if prompt && prompt["tag"] == "synonyms"
    halt 400, { error: "ユーザー入力が見つかりません。" }.to_json unless user_message

    return({
      message: synonymize_text(user_message["content"] || user_message[:content] || ""),
      mode: "synonyms",
      prompt_id: prompt["id"]
    }.to_json)
  end

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

get "/api/synonyms" do
  lemma = params[:lemma]&.strip
  halt 400, { error: "lemma は必須です。" }.to_json if lemma.nil? || lemma.empty?

  {
    lemma: lemma,
    synonyms: synonym_candidates(lemma)
  }.to_json
end
