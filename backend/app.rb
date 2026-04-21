require "json"
require "net/http"
require "sinatra"

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 4567)

before do
  headers(
    "Access-Control-Allow-Origin" => "http://localhost:5173",
    "Access-Control-Allow-Methods" => "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers" => "Content-Type"
  )
end

options "*" do
  200
end

get "/health" do
  content_type :json
  { status: "ok" }.to_json
end

post "/chat" do
  content_type :json

  request_body = request.body.read
  payload = request_body.empty? ? {} : JSON.parse(request_body)
  messages = payload["messages"] || []

  uri = URI("http://localhost:11434/api/chat")
  ollama_request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  ollama_request.body = {
    model: "gemma3:1b",
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
