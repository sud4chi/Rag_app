require "json"
require "net/http"
require "sinatra"

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 4567)

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
end

before do
  headers(
    "Access-Control-Allow-Origin" => cors_origin,
    "Access-Control-Allow-Methods" => "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers" => "Content-Type",
    "Vary" => "Origin"
  )
end

options "*" do
  200
end

get "/health" do
  redirect to("/api/health"), 307
end

get "/api/health" do
  content_type :json
  {
    status: "ok",
    model: ollama_model
  }.to_json
end

post "/chat" do
  redirect to("/api/chat"), 307
end

post "/api/chat" do
  content_type :json

  request_body = request.body.read
  payload = request_body.empty? ? {} : JSON.parse(request_body)
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
