import Config

config :taskbar_example, TaskbarExampleWeb.Endpoint,
  secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
  server: true
