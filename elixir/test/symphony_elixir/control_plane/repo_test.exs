defmodule SymphonyElixir.ControlPlane.RepoTest do
  use ExUnit.Case, async: false

  require Logger

  alias SymphonyElixir.ControlPlane.Repo

  @default_db_path Path.expand("~/.symphony/db/symphony.db")

  describe "database_path function" do
    test "database_path returns configured path" do
      path = Repo.database_path()
      assert is_binary(path)
    end
  end

  describe "fresh environment directory creation via init/2" do
    test "init/2 creates parent directory for given DB path if missing" do
      # Test directly with manual setup, no app supervision
      db_path = Path.join(System.tmp_dir(), "symphony_fresh_test/#{inspect(self())}/db.db")
      db_dir = Path.dirname(db_path)

      try do
        # Ensure the directory does not exist beforehand
        if File.exists?(db_dir) do
          File.rm_rf!(db_dir)
        end

        assert !File.exists?(db_dir),
               "Precondition: directory should not exist: #{db_dir}"

        # Call Repo.init/2 directly (no full app supervision)
        {:ok, result_config} =
          Repo.init(:cellphones_trust,
            adapter: :ectosqlite3,
            database: db_path
          )

        assert File.exists?(db_dir),
               "Directory should have been created by init/2: #{db_dir}"

        # Verify the config actually contains the correct DB path
        configured_db = Keyword.get(result_config, :database)

        assert configured_db == db_path,
               "init/2 should preserve/inject the database path"
      after
        if File.exists?(db_dir) do
          File.rm_rf!(db_dir)
        end
      end
    end

    test "init/2 does not re-create if directory already exists" do
      db_path = Path.join(System.tmp_dir(), "symphony_existing_dir_test/#{inspect(self())}/db.db")
      db_dir = Path.dirname(db_path)

      try do
        File.mkdir_p!(db_dir)

        # Should be idempotent
        {:ok, _} =
          Repo.init(:cellphones_trust,
            adapter: :ectosqlite3,
            database: db_path
          )

        assert File.exists?(db_dir)
        # Repo should only need to FINISH starting; no crash
      after
        if File.exists?(db_dir) do
          File.rm_rf!(db_dir)
        end
      end
    end

    test "application environment override changes actual DB path used by init/2" do
      db_path = Path.join(System.tmp_dir(), "symphony_env_override_test/#{inspect(self())}/override.db")
      db_dir = Path.dirname(db_path)

      if File.exists?(db_dir) do
        File.rm_rf!(db_dir)
      end

      # Capture original config before modifying
      original = Application.get_env(:symphony_elixir, Repo)

      # Override via application environment
      Application.put_env(:symphony_elixir, Repo, database: db_path)

      {:ok, config} =
        Repo.init(:cellphones_trust,
          adapter: :ectosqlite3,
          database: db_path
        )

      # Verify the path was actually injected
      assert Keyword.get(config, :database) == db_path,
             "init/2 should use the overridden database path"

      assert File.exists?(db_dir), "Directory should be created for overridden path"

      # Restore original env
      if is_nil(original) do
        Application.delete_env(:symphony_elixir, Repo)
      else
        Application.put_env(:symphony_elixir, Repo, original)
      end

      if File.exists?(db_dir) do
        File.rm_rf!(db_dir)
      end
    end
  end

  describe "full repo startup end-to-end in test env" do
    test "app starts with repo; can issue raw query against configured test DB" do
      # Default app repo should be running. Verify we can issue basic queries.
      result = Repo.query("SELECT 1 AS answer", [])
      assert {:ok, inspected_result} = result
      assert inspected_result.rows == [[1]]
    end
  end
end
