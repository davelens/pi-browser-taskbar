# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

base = URI(ENV.fetch("PI_BROWSER_TASKBAR_PUMA_URL"))
cookie = nil

request = lambda do |method, path, body: nil, token: nil|
  uri = base + path
  klass = {get: Net::HTTP::Get, post: Net::HTTP::Post}.fetch(method)
  req = klass.new(uri)
  req["Cookie"] = cookie if cookie
  req["Content-Type"] = "application/json" if body
  req["X-CSRF-Token"] = token if token
  req.body = body if body
  response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  cookie = response["set-cookie"]&.split(";", 2)&.first || cookie
  response
end

response = nil
200.times do
  begin
    response = request.call(:get, "/")
    break if response.code == "200"
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET
    nil
  end
  sleep 0.05
end
raise "Puma did not boot the generated Rails application" unless response&.code == "200"
raise "Puma response omitted ERB annotations" unless response.body.include?("BEGIN app/views/scenarios/index.html.erb")
token = response.body[/data-csrf-token="([^"]+)"/, 1]
raise "Puma response omitted taskbar bootstrap" unless token

asset = request.call(:get, "/dev/pi-browser-taskbar/assets/pi_browser_taskbar.js")
raise "Puma did not serve the packaged asset" unless asset.code == "200" && asset.body.include?("productVersion")

snapshot = nil
200.times do
  state = request.call(:get, "/dev/pi-browser-taskbar/state")
  snapshot = JSON.parse(state.body)
  break if snapshot.dig("session", "status") == "ready"
  sleep 0.05
end
raise "Puma could not reach the project broker" unless snapshot&.dig("session", "status") == "ready"
session_id = snapshot.dig("session", "id")

task = File.read(ENV.fetch("PI_BROWSER_TASKBAR_TASK"))
created = request.call(:post, "/dev/pi-browser-taskbar/tasks", body: task, token: token)
raise "Puma mutation failed with #{created.code}" unless created.code == "202"
200.times do
  snapshot = JSON.parse(request.call(:get, "/dev/pi-browser-taskbar/state").body)
  break if snapshot.dig("task", "status") == "completed"
  sleep 0.05
end
raise "Puma task did not complete" unless snapshot.dig("task", "status") == "completed"

File.write(ENV.fetch("PI_BROWSER_TASKBAR_PUMA_OBSERVATION"), JSON.pretty_generate(
  "mode" => ENV.fetch("PI_BROWSER_TASKBAR_PUMA_MODE"),
  "workers" => Integer(ENV.fetch("PI_BROWSER_TASKBAR_PUMA_WORKERS")),
  "preload" => ENV.fetch("PI_BROWSER_TASKBAR_PUMA_PRELOAD") == "true",
  "session_id" => session_id,
  "boot" => true,
  "route" => true,
  "asset" => true,
  "mutation" => true,
  "annotation" => true
))
puts "Rails Puma #{ENV.fetch("PI_BROWSER_TASKBAR_PUMA_MODE")} conformance passed"
