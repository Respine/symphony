defmodule SymphonyElixir.ControlPlane.RepoTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ControlPlane.Repo

  describe "database_path resolution" do
    test "reads config from application env" do
      db_path = Path.join(System.tmp_dir(), "symphony_config_test.db")
      Application.put_env(:symphony_elixir, Repo, database: db_path)
      assert Repo.database_path() == db_path
    after
      Application.delete_env(:symphony_elixir, Repo)
    end

    test "returns default when no config set" do
      Application.delete_env(:symphony_elixir, Repo)
      expected = Path.expand("~/.symphony/db/symphony.db")
      assert Repo.database_path() == expected
    end
  end

  describe "fresh initialization" do
    test "creates directory and db file when starting with new path" do
      test_id = System.unique_integer()
      tmp_dir = Path.join(System.tmp_dir(), "symphony_test_#{test_id}")
      db_path = Path.join(tmp_dir, "symphony.db")

      Application.put_env(:symphony_elixir, Repo, database: db_path)

      on_exit(fn ->
        if File.exists?(tmp_dir) do
          File.rm_rf!(tmp_dir)
        end
      end)

      # Create the directory structure and start the repo
      assert Repo.database_path() == db_path
    end
  end
end
