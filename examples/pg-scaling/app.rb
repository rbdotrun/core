# frozen_string_literal: true

require "sinatra"
require "pg"
require "json"

set :port, 3000
set :bind, "0.0.0.0"

def db
  @db ||= PG.connect(ENV.fetch("DATABASE_URL"))
end

def setup_schema!
  db.exec <<~SQL
    CREATE TABLE IF NOT EXISTS entries (
      id SERIAL PRIMARY KEY,
      message TEXT NOT NULL,
      created_at TIMESTAMP DEFAULT now()
    )
  SQL
end

configure do
  setup_schema!
end

get "/" do
  rows = db.exec("SELECT id, message, created_at FROM entries ORDER BY id DESC LIMIT 50")
  content_type :json
  rows.map { |r| { id: r["id"].to_i, message: r["message"], created_at: r["created_at"] } }.to_json
end

post "/entries" do
  payload = JSON.parse(request.body.read)
  message = payload["message"] || "hello at #{Time.now}"
  db.exec_params("INSERT INTO entries (message) VALUES ($1)", [message])
  status 201
  content_type :json
  { status: "created", message: message }.to_json
end

get "/health" do
  db.exec("SELECT 1")
  "ok"
end
