defmodule SymphonyElixir.ControlPlane.RepoTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ControlPlane.Repo

  test "database_path uses env var when provided" do
    with_config_db_path("/tmp/symphony_test_app_env.db", fn ->
      assert Repo.database_path() == "/tmp/symphony_test_app_env.db"
    end)
  end

  test "database_path correctly expands homedir path when provided" do
    with_config_db_path("~/lesstest/symphony_expanded.db", fn ->
      expected = Path.expand("~/lesstest/symphony_expanded.db")
      assert Repo.database_path() == expected
    end)
  end

  test "database_path falls back to module default when config removed" do
    original = Application.get_env(:symphony_elixir, :db_path)

    try do
      Application.delete_env(:symphony_elixir, :db_path)
      # Without application env, falls back to the module default
      assert Repo.database_path() == "symphony.db"
    after
      case original do
        nil -> Application.delete_env(:symphony_elixir, :db_path)
        v -> Application.put_env(:symphony_elixir, :db_path, v)
      end
    end
  end

  test "Repo.init/2 injects database path from database_path/0" do
    original = Application.get_env(:symphony_elixir, :db_path)

    try do
      Application.put_env(:symphony_elixir, :db_path, "injected.db")

      # Repo.init should transform options to include :database
      {:ok, config} = Repo.init(:normal, [])
      assert config[:database] == "injected.db"
    after
      case original do
        nil -> Application.delete_env(:symphony_elixir, :db_path)
        v -> Application.put_env(:symphony_elixir, :db_path, v)
      end
    end
  end

  defp with_config_db_path(path, fun) do
    original = Application.get_env(:symphony_elixir, :db_path)

    try do
      Application.put_env(:symphony_elixir, :db_path, path)
      fun.()
    after
      case original do
        nil -> Application.delete_env(:symphony_elixir, :db_path)
        v -> Application.put_env(:symphony_elixir, :db_path, v)
      end
    end
  end
end
