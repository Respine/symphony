defmodule SymphonyElixir.ControlPlane.MigrationBootstrapContract do
  @moduledoc """
  Acceptance contract for the Control Plane migration bootstrap (RES-335).

  This file is intentionally named `.exs` (not `*_test.exs`) so the default
  `mix test` suite does not run it. Run it explicitly:

      mix test test/symphony_elixir/control_plane/migration_bootstrap_contract.exs

  While the bootstrap API below is missing it fails with a single clear
  assertion naming the missing function. Once RES-336 implements it, the
  same file fully verifies the frozen behavior.

  ## Frozen contract

  `SymphonyElixir.ControlPlane.Migrations.run/1` runs the Control Plane
  migration bootstrap (up only) against a target SQLite database.

  Options:

    * `:database` (binary) - path of the target SQLite file.
      Default: `SymphonyElixir.ControlPlane.Repo.database_path()`.
    * `:repo` (module) - the Ecto repo that owns the adapter and migrations.
      Default: `SymphonyElixir.ControlPlane.Repo`.
    * `:migrations_path` (binary) - directory containing the migration files.
      Default: `priv/repo/migrations` of the `:symphony_elixir` app.

  Guarantees:

    * The target file is created when absent; a nonexistent file is the
      canonical empty-DB starting point.
    * Returns `{:ok, versions}` where `versions` are the migration versions
      applied by this call, ascending, without duplicates. A first run on an
      empty DB applies all migrations (non-empty list); a second run on the
      same DB returns `{:ok, []}` - no version is re-applied and no
      duplicate-migration error is raised.
    * Applied versions are recorded in the standard Ecto `schema_migrations`
      bookkeeping table inside the target database; re-runs never add rows.
    * Must not depend on the app-supervised repo process, and must not create
      or modify any file other than the target database and its SQLite
      sidecar files. In particular it must never touch the default user
      state directory (the parent of the default `db_path`).
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.ControlPlane.Repo

  @contract_module SymphonyElixir.ControlPlane.Migrations
  @bookkeeping_table "schema_migrations"

  setup do
    temp_root =
      Path.join(System.tmp_dir!(), "symphony-migration-bootstrap-contract-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_root)

    on_exit(fn -> File.rm_rf(temp_root) end)

    {:ok, db_path: Path.join(temp_root, "symphony.db")}
  end

  test "empty temp DB bootstrap is idempotent, keeps stable bookkeeping, stays queryable, and leaves the user state dir untouched",
       %{db_path: db_path} do
    assert_api_present()

    user_state_before = snapshot_dir(user_state_dir())

    # 1. A unique empty temp DB can run the migration bootstrap.
    assert not File.exists?(db_path), "temp DB must start empty (no file at #{db_path})"

    first_versions =
      case run_bootstrap(db_path) do
        {:ok, versions} ->
          assert_valid_versions(versions, "first run")
          assert File.regular?(db_path), "bootstrap must create the target database file"
          versions

        {:error, reason} ->
          flunk("first bootstrap run must succeed on an empty DB, got: #{inspect(reason)}")

        other ->
          flunk("first bootstrap run must return {:ok, versions}, got: #{inspect(other)}")
      end

    # 2. Running the same bootstrap again succeeds and is a no-op.
    case run_bootstrap(db_path) do
      {:ok, []} ->
        :ok

      {:ok, versions} ->
        flunk("second bootstrap run must not re-apply migrations, got: #{inspect(versions)}")

      {:error, reason} ->
        flunk("second bootstrap run must not fail (no duplicate migration error), got: #{inspect(reason)}")

      other ->
        flunk("second bootstrap run must return {:ok, versions}, got: #{inspect(other)}")
    end

    # 3. Bookkeeping stays stable: exactly the applied versions, no duplicates.
    bookkeeping = read_bookkeeping(db_path)

    assert bookkeeping == first_versions,
           "bookkeeping must equal the versions applied by the first run; " <>
             "bookkeeping=#{inspect(bookkeeping)}, first run=#{inspect(first_versions)}"

    # 4. The DB remains queryable after the second run.
    assert query_ok?(db_path), "DB must remain queryable after the second run: #{db_path}"

    # 5. No user state directory is touched.
    assert snapshot_dir(user_state_dir()) == user_state_before,
           "user state dir must not be touched by the bootstrap; before=#{inspect(user_state_before)}"
  end

  defp assert_api_present do
    loaded = Code.ensure_loaded?(@contract_module)
    exported = loaded and function_exported?(@contract_module, :run, 1)

    unless exported do
      flunk("""
      missing migration-bootstrap API (RES-336 is expected to implement it):
        - module #{@contract_module} (loaded: #{inspect(loaded)})
        - exported function run/1
      The frozen contract is documented in the moduledoc of this file.
      """)
    end
  end

  defp run_bootstrap(db_path) do
    if Code.ensure_loaded?(@contract_module) and function_exported?(@contract_module, :run, 1) do
      try do
        :erlang.apply(@contract_module, :run, database: db_path)
      catch
        kind, value -> {kind, value}
      end
    end
  end

  defp assert_valid_versions(versions, label) do
    assert is_list(versions), "#{label}: versions must be a list, got: #{inspect(versions)}"
    assert versions != [], "#{label}: bootstrapping an empty DB must apply at least one migration"

    assert Enum.all?(versions, fn version -> is_integer(version) and version > 0 end),
           "#{label}: versions must be positive integers, got: #{inspect(versions)}"

    assert versions == Enum.sort(versions),
           "#{label}: versions must be ascending, got: #{inspect(versions)}"

    assert versions == Enum.uniq(versions),
           "#{label}: versions must not contain duplicates, got: #{inspect(versions)}"
  end

  defp user_state_dir do
    # The default control-plane database lives in the user state directory;
    # `Repo.database_path/0` resolves and expands it, so its parent is the
    # directory this contract observes as untouched.
    Path.dirname(Repo.database_path())
  end

  defp read_bookkeeping(db_path) do
    case Exqlite.Sqlite3.open(db_path) do
      {:ok, conn} ->
        try do
          case Exqlite.Sqlite3.prepare(conn, "SELECT version FROM #{@bookkeeping_table} ORDER BY version") do
            {:ok, stmt} ->
              rows =
                case Exqlite.Sqlite3.fetch_all(conn, stmt) do
                  {:ok, rows} -> rows
                  {:error, reason} -> raise "bookkeeping read failed: #{inspect(reason)}"
                end

              Exqlite.Sqlite3.release(conn, stmt)
              for [version] <- rows, do: version

            {:error, reason} ->
              raise "bookkeeping table #{@bookkeeping_table} is missing or unreadable: #{inspect(reason)}"
          end
        after
          Exqlite.Sqlite3.close(conn)
        end

      {:error, reason} ->
        raise "cannot open #{db_path} to read bookkeeping: #{inspect(reason)}"
    end
  end

  defp query_ok?(db_path) do
    case Exqlite.Sqlite3.open(db_path) do
      {:ok, conn} ->
        try do
          case Exqlite.Sqlite3.prepare(conn, "SELECT 1") do
            {:ok, stmt} ->
              result = Exqlite.Sqlite3.fetch_all(conn, stmt)
              Exqlite.Sqlite3.release(conn, stmt)
              result == {:ok, [[1]]}

            {:error, _reason} ->
              false
          end
        after
          Exqlite.Sqlite3.close(conn)
        end

      _ ->
        false
    end
  end

  defp snapshot_dir(dir) do
    if File.dir?(dir) do
      entries =
        dir
        |> list_entries()
        |> Enum.map(fn path ->
          stat = File.stat!(path, time: :millisecond)
          {Path.relative_to(path, dir), stat.size, stat.mtime}
        end)
        |> Enum.sort()

      {:present, entries}
    else
      {:absent}
    end
  end

  defp list_entries(dir) do
    File.ls!(dir)
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.flat_map(fn path ->
      if File.dir?(path) do
        [path] ++ list_entries(path)
      else
        [path]
      end
    end)
  end
end
