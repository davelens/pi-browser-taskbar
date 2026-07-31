import Config

config :taskbar_example, TaskbarExampleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
  server: true,
  code_reloader: true,
  check_origin: false,
  watchers: []
