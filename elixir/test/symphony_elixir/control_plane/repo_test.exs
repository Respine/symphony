defmodule SymphonyElixir.ControlPlane.RepoTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ControlPlane.Repo

  setup_all do
    # Config once for the entire test module — shared across all tests
    user_tmp = System.tmp_dir!()
    unique_dir = Path.join(user_tmp, "symphony_test_#{System.unique_integer([:positive])}")

    File.mkdir!(unique_dir)

    # Configure the application to use our temporary database path
    db_path = Path.join(unique_dir, "test.db")

    Application.put_env(:symphony_elixir, Repo,
      adapter: Ecto.Adapters.SQLite3,
      database: db_path
    )

    # Restart the whole application to see our new DB path
    Application.stop(:symphony_elixir)
    Application.start(:symphony_elixir)

    %{
      unique_dir: unique_dir,
      db_path: db_path
    }
  end

  test "creates the database file under the configured path", %{db_path: db_path, unique_dir: unique_dir} do
    # Short delay to allow the supervisor to fully boot
    Process.sleep(100)

    assert File.exists?(db_path)
    assert Path.dirname(db_path) == unique_dir
  end

  test "can execute actual SQLite statements" do
    # Ensure db fully bootstrapped
    Process.sleep(100)

    Repo.query!("CREATE TABLE IF NOT EXISTS test_items (id INTEGER PRIMARY KEY, msg TEXT)")
    Repo.query!("INSERT OR IGNORE INTO test_items (id, msg) VALUES (1, 'hello world')")

    result = Repo.query!("SELECT msg FROM test_items LIMIT 1")
    assert length(result.rows) == 1
    assert hd(hd(result.rows)) == "hello world"
  end

  test "reverts to home-state-dir default when env is missing" do
    # Delete env temporarily to simulate a fresh start
    Application.delete_env(:symphony_elixir, Repo)

    # Construct the expected default path
    home = System.user_home!()
    expected_default = Path.join([home, ".local", "share", "symphony", "symphony.db"])

    assert Repo.db_path() == expected_default, "not in homedir default"
  end
end
