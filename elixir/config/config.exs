import Config

# Symphony Control Plane Repo Configuration
# Production default: SQLite database in ~/.symphony/db/symphony.db
# For testing environments, override like:
#   CONFIG_TEST_DB_FILE=/tmp/symphony_test.db mix test

config :symphony_elixir, SymphonyElixir.ControlPlane.Repo,
  database: "/tmp/symphony_test_db/symphony.db",
  pool_size: 1
