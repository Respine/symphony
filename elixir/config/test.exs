import Config

# For testing, use a unique SQLite file per test process to avoid conflicts
test_db_path = Path.join(System.tmp_dir(), "symphony_test_#{System.os_pid()}.db")

config :symphony_elixir, SymphonyElixir.ControlPlane.Repo,
  database: test_db_path,
  pool_size: 1

# Provide default test tracker config so WorkflowStore validation passes
config :symphony_elixir,
  tracker: %{
    kind: "linear",
    endpoint: "https://api.linear.app/graphql",
    api_key: "LINEAR_TOKEN_FOR_TESTS",
    project_slug: "TEST"
  }
