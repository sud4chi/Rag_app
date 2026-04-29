require "fileutils"
require "json"
require "logger"
require "net/http"
require "open3"
require "sqlite3"
require "sinatra"
require "time"
require 'dotenv/load'

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

def ensure_sudachi_available!(python_command, script_path)
  stdout, stderr, status = Open3.capture3(python_command, script_path, "--healthcheck")
  return if status.success?

  detail = stderr.to_s.strip
  detail = stdout.to_s.strip if detail.empty?
  raise "SudachiPy を初期化できません。`pip install -r backend/requirements.txt` を実行してください。詳細: #{detail}"
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

  def app_logger
    settings.app_logger
  end

  def sudachi_python
    settings.sudachi_python
  end

  def sudachi_script
    settings.sudachi_script
  end

  def log_info(message)
    app_logger&.info(message)
  end

  def find_prompt(id)
    return nil if id.nil? || id.to_s.strip.empty?

    db.get_first_row("SELECT * FROM prompts WHERE id = ?", id)
  end

  def latest_user_message(messages)
    messages.reverse.find { |message| message["role"] == "user" || message[:role] == "user" }
  end

  def ollama_chat(messages)
    log_info("ollama request messages=#{messages.length} model=#{ollama_model}")

    request = Net::HTTP::Post.new(ollama_uri, "Content-Type" => "application/json")
    request.body = {
      model: ollama_model,
      stream: false,
      messages: messages
    }.to_json

    response = Net::HTTP.start(ollama_uri.hostname, ollama_uri.port) do |http|
      http.request(request)
    end

    halt response.code.to_i, response.body unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    data.dig("message", "content") || ""
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
    return false if subpos.to_s.include?("非自立")

    true
  end

  def base_form(surface, lemma)
    return surface if lemma.nil? || lemma.empty? || lemma == "*"

    lemma
  end

  def synonymize_text(text)
    output = []

    sudachi_tokens(text.to_s).each do |node|
      surface = node.fetch("surface", "").to_s
      next if surface.empty?

      features = Array(node["pos"])
      unless replaceable_node?(surface, features)
        output << surface
        next
      end

      lemma = base_form(surface, node["lemma"].to_s)
      candidates = synonym_candidates(lemma)

      output << (candidates.empty? ? surface : candidates.sample(random: settings.random))
    end

    output.join
  end

  def sudachi_tokens(text)
    stdout, stderr, status = Open3.capture3(
      sudachi_python,
      sudachi_script,
      stdin_data: { text: text, mode: ENV.fetch("SUDACHI_SPLIT_MODE", "C") }.to_json
    )

    unless status.success?
      detail = stderr.to_s.strip
      detail = stdout.to_s.strip if detail.empty?
      raise "SudachiPy の解析に失敗しました: #{detail}"
    end

    JSON.parse(stdout)
  rescue JSON::ParserError => e
    raise "SudachiPy の応答を解釈できませんでした: #{e.message}"
  end

  def polish_synonymized_text(original_text, synonymized_text)
    ollama_chat([
      {
        role: "system",
        content: "あなたは日本語の校正者です。入力された文を自然で正しい日本語に整えてください。意味はできるだけ維持し、説明は付けず、整形後の文だけを返してください。"
      },
      {
        role: "user",
        content: <<~TEXT
          元の文:
          #{original_text}

          類義語置換後の文:
          #{synonymized_text}

          類義語置換後の文をもとに、自然で正しい日本語の1文に整えてください。
        TEXT
      }
    ])
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
  log_file = File.expand_path("app.log", __dir__)
  FileUtils.touch(log_file)
  logger = Logger.new(log_file, 10, 1_048_576)
  logger.level = Logger::INFO
  logger.formatter = proc do |severity, datetime, _progname, msg|
    "#{datetime.utc.iso8601} #{severity} #{msg}\n"
  end
  set :app_logger, logger

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

  sudachi_python = ENV.fetch("SUDACHI_PYTHON", "python3")
  sudachi_script = File.expand_path("scripts/sudachi_tokenize.py", __dir__)
  ensure_sudachi_available!(sudachi_python, sudachi_script)
  set :sudachi_python, sudachi_python
  set :sudachi_script, sudachi_script

  logger.info("app booted db=#{db_file} wnjpn_db=#{wnjpn_file} model=#{ENV.fetch("OLLAMA_MODEL", "gemma3:1b")} sudachi_python=#{sudachi_python}")
end

before do
  headers(
    "Access-Control-Allow-Origin" => cors_origin,
    "Access-Control-Allow-Methods" => "GET,POST,PUT,DELETE,OPTIONS",
    "Access-Control-Allow-Headers" => "Content-Type",
    "Vary" => "Origin"
  )
  content_type :json if request.path_info.start_with?("/api/")
  app_logger&.info("request method=#{request.request_method} path=#{request.path_info} ip=#{request.ip}")
end

options "*" do
  200
end

get "/health" do
  redirect to("/api/health"), 307
end

get "/api/health" do
  log_info("health check")
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
  log_info("chat received prompt_id=#{payload["prompt_id"] || "none"} messages=#{messages.length} prompt_tag=#{prompt && prompt["tag"]}")

  if prompt && prompt["tag"] == "synonyms"
    halt 400, { error: "ユーザー入力が見つかりません。" }.to_json unless user_message

    original_text = user_message["content"] || user_message[:content] || ""
    synonymized_text = synonymize_text(original_text)
    log_info("synonyms mode original=#{original_text.inspect} synonymized=#{synonymized_text.inspect}")

    return({
      message: polish_synonymized_text(original_text, synonymized_text),
      mode: "synonyms_llm",
      prompt_id: prompt["id"]
    }.to_json)
  end

  {
    message: ollama_chat(messages)
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
  log_info("prompt list")
  rows = db.execute("SELECT * FROM prompts ORDER BY datetime(updated_at) DESC, id DESC")
  { prompts: rows.map { |row| serialize_prompt(row) } }.to_json
end

get "/api/prompts/:id" do
  log_info("prompt fetch id=#{params[:id]}")
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
  log_info("prompt created title=#{payload["title"].strip.inspect} tag=#{tag.inspect}")

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
  log_info("prompt updated id=#{params[:id]} title=#{payload["title"].strip.inspect} tag=#{tag.inspect}")

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
  log_info("prompt deleted id=#{params[:id]}")
  status 204
  body ""
end

get "/api/synonyms" do
  lemma = params[:lemma]&.strip
  halt 400, { error: "lemma は必須です。" }.to_json if lemma.nil? || lemma.empty?
  log_info("synonym lookup lemma=#{lemma.inspect}")

  {
    lemma: lemma,
    synonyms: synonym_candidates(lemma)
  }.to_json
end
