defmodule SymphonyElixir.ControlPlane.RepoTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.ControlPlane.Repo

  test "database_path uses application config for db location" do
    Application.put_env(:symphony_elixir, :db_path, "/tmp/symphony_test.db")

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :db_path, "~/code/symphony/state/symphony.db")
    end)

    path = Repo.database_path()
    assert path == "/tmp/symphony_test.db"
  end

  test "database_path expands default to ~/code/symphony/state/symphony.db" do
    home = System.user_home()
    expected = home <> "/code/symphony/state/symphony.db"
    actual = Repo.database_path()
    assert actual == expected, "expected #{expected}, got #{actual}"
  end
end
