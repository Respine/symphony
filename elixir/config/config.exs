import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, db_path: System.get_env("SYMPHONY_DB_PATH") || "~/code/symphony/state/symphony.db"

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

if config_env() == :test do
  test_db_dir = Path.join(System.tmp_dir(), "symphony_test_db")
  test_db_file = Path.join(test_db_dir, "symphony.db")

  config :symphony_elixir,
    workflow_file_path: Path.expand("../test/fixtures/startup_workflow.md", __DIR__),
    temp_dir: Path.join(System.tmp_dir(), "symphony_test_working/")

  config :symphony_elixir, SymphonyElixir.ControlPlane.Repo, database: test_db_file
end
