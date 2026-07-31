import Config

config :taskbar_example, TaskbarExampleWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [html: TaskbarExampleWeb.ErrorHTML], layout: false],
  pubsub_server: TaskbarExample.PubSub,
  live_view: [signing_salt: "example-signing-salt"]

config :phoenix, :json_library, Jason
import_config "#{config_env()}.exs"
