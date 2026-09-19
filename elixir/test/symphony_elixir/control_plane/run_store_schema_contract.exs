defmodule SymphonyElixir.ControlPlane.RunStoreSchemaContract do
  @moduledoc """
  Schema acceptance contract for the RunStore tables (RES-337).

  This file is intentionally NOT named `*_test.exs`: the default `mix test`
  must stay green while the schema does not exist yet. Run it explicitly:

      mix test test/symphony_elixir/control_plane/run_store_schema_contract.exs

  The contract opens a unique temporary SQLite database, runs the project
  migrations against it (when a migrations directory exists yet), and then
  asserts the frozen schema contract from RES-314 / RES-296 using raw SQL
  only (PRAGMA introspection plus behavioral inserts). It does not depend
  on any RunStore module, does not define production code, and never
  touches the user's state database.

  The contract is allowed to FAIL while `runs`, `run_attempts`, and
  `run_events` are missing; it must not fail because it cannot compile.
  It is expected to turn green only when RES-338 lands the migrations.

  ## Frozen contract

  `runs` — one logical execution lifecycle for one tracker work item:

      id          primary key
      tracker_ref NOT NULL  (tracker issue ref, e.g. "RES-337")
      tracker_url nullable  (tracker-provided URL)
      started_at  nullable
      ended_at    nullable
      status      NOT NULL  (string)
      outcome     nullable  (string)

  `run_attempts` — one actual worker process / retry; a run may have
  several attempts, retries never create a new run:

      id          primary key
      run_id      NOT NULL, foreign key -> runs(id)
      number      NOT NULL  (1-based attempt number)
      started_at  nullable
      ended_at    nullable
      outcome     nullable  (string)
      runtime_ref nullable  (runtime identity of the worker, e.g. a
                            Codex thread id or worker address)

  `run_events` — append-only ordered event stream:

      id          primary key
      run_id      NOT NULL, foreign key -> runs(id)
      attempt_id  nullable, foreign key -> run_attempts(id)
                  (run-level events happen before the first attempt and
                  after the last one, so the reference is optional)
      seq         NOT NULL  (integer; strictly increasing per run is
                            enforced by the store, uniqueness by the schema)
      occurred_at NOT NULL
      source      NOT NULL  (string, open vocabulary: agent | human |
                            symphony | entire | git | ...; no closed enum)
      type        NOT NULL  (string, open vocabulary; no closed enum)
      payload     NOT NULL  (JSON text; must round-trip unknown fields)

  Constraints and indexes required by the contract:

      - UNIQUE (run_id, seq) on run_events, enforced by SQLite
      - index on run_events supporting (run_id, seq) lookups
      - index on run_events supporting attempt_id lookups
      - index on run_attempts supporting run_id lookups

  Timestamp columns are intentionally not pinned to a storage type by this
  contract; behavioral inserts below use RFC 3339 strings, which round-trip
  through both TEXT and NUMERIC affinities.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.ControlPlane.RunStoreSchemaContract.Repo

  @migrations_dirs ["priv/repo/migrations", "priv/migrations"]

  @runs_fields [
    {"id", [pk: true]},
    {"tracker_ref", [required: true]},
    {"tracker_url", []},
    {"started_at", []},
    {"ended_at", []},
    {"status", [required: true]},
    {"outcome", []}
  ]

  @run_attempts_fields [
    {"id", [pk: true]},
    {"run_id", [required: true]},
    {"number", [required: true]},
    {"started_at", []},
    {"ended_at", []},
    {"outcome", []},
    {"runtime_ref", []}
  ]

  @run_events_fields [
    {"id", [pk: true]},
    {"run_id", [required: true]},
    {"attempt_id", []},
    {"seq", [required: true]},
    {"occurred_at", [required: true]},
    {"source", [required: true]},
    {"type", [required: true]},
    {"payload", [required: true]}
  ]

  @expected_foreign_keys %{
    "run_attempts" => [
      {"run_id", "runs", required: true}
    ],
    "run_events" => [
      {"run_id", "runs", required: true},
      {"attempt_id", "run_attempts", required: false}
    ]
  }

  @expected_indexes [
    %{"table" => "run_events", "leading" => ["run_id", "seq"], "unique" => true},
    %{"table" => "run_events", "leading" => ["attempt_id"], "unique" => false},
    %{"table" => "run_attempts", "leading" => ["run_id"], "unique" => false}
  ]

  @timestamp "2026-09-18T10:00:00Z"
  @payload %{"unknown_field" => "kept", "nested" => %{"a" => 1, "b" => true, "c" => nil}, "list" => [1, "two", 3.5], "unicode" => "中文"}

  setup do
    {:ok, _} = Application.ensure_all_started(:exqlite)
    db_path = unique_temp_db_path()
    migration_outcome = migrate_temp_db(db_path)
    {:ok, db} = Exqlite.start_link(database: db_path, foreign_keys: :on)

    on_exit(fn ->
      # ExUnit may tear down the test-case process before this callback runs;
      # the pool is then already gone. Cleanup must never change the outcome.
      try do
        GenServer.stop(db)
      catch
        :exit, _reason -> :ok
      end

      for suffix <- ["", "-journal", "-wal", "-shm"] do
        try do
          File.rm!(db_path <> suffix)
        rescue
          _ -> :ok
        end
      end
    end)

    %{db: db, db_path: db_path, migration_outcome: migration_outcome}
  end

  ## Schema introspection tests

  test "runs table exists with the minimum fields", %{db: db, migration_outcome: outcome} do
    assert_table_exists(db, "runs", outcome)
    assert_fields(db, "runs", @runs_fields)
  end

  test "run_attempts table exists with the minimum fields", %{db: db, migration_outcome: outcome} do
    assert_table_exists(db, "run_attempts", outcome)
    assert_fields(db, "run_attempts", @run_attempts_fields)
  end

  test "run_events table exists with the minimum fields", %{db: db, migration_outcome: outcome} do
    assert_table_exists(db, "run_events", outcome)
    assert_fields(db, "run_events", @run_events_fields)
  end

  test "run_attempts references runs", %{db: db, migration_outcome: outcome} do
    assert_table_exists(db, "run_attempts", outcome)
    assert_foreign_keys(db, "run_attempts", @expected_foreign_keys["run_attempts"])

    run_id = insert_run(db)
    _attempt_id = insert_attempt(db, run_id)

    result =
      try do
        Exqlite.query(db, insert_sql("run_attempts", %{"run_id" => 999_999_999, "number" => 1}), [])
      rescue
        error in Exqlite.Error -> {:error, error}
      end

    assert {:error, %Exqlite.Error{message: message}} = result,
           "expected inserting an attempt with a missing run to be rejected by the foreign key"

    assert message =~ ~r/foreign key/i, "unexpected SQLite error for the run_id foreign key: #{message}"
  end

  test "run_events references run and optional attempt", %{db: db, migration_outcome: outcome} do
    assert_table_exists(db, "run_events", outcome)
    assert_foreign_keys(db, "run_events", @expected_foreign_keys["run_events"])
    assert_event_attempt_is_optional(db)

    run_id = insert_run(db)
    attempt_id = insert_attempt(db, run_id)

    assert_event_ok(db, %{"run_id" => run_id, "attempt_id" => nil, "seq" => 1, "type" => "run.created"})
    assert_event_ok(db, %{"run_id" => run_id, "attempt_id" => attempt_id, "seq" => 2, "type" => "attempt.started"})

    assert_event_fk_rejected(db, %{"run_id" => 999_999_999, "attempt_id" => nil, "seq" => 1, "type" => "run.created"})
    assert_event_fk_rejected(db, %{"run_id" => run_id, "attempt_id" => 999_999_999, "seq" => 3, "type" => "attempt.started"})
  end

  test "(run_id, seq) uniqueness on run_events is enforced by SQLite", %{db: db, migration_outcome: outcome} do
    assert_table_exists(db, "run_events", outcome)
    assert_unique_index(db, "run_events", ["run_id", "seq"])

    run_id = insert_run(db)
    assert_event_ok(db, %{"run_id" => run_id, "attempt_id" => nil, "seq" => 1, "type" => "run.created"})

    duplicate =
      try do
        Exqlite.query(
          db,
          insert_sql("run_events", %{"run_id" => run_id, "attempt_id" => nil, "seq" => 1, "type" => "attempt.started"}),
          []
        )
      rescue
        error in Exqlite.Error -> {:error, error}
      end

    assert {:error, %Exqlite.Error{message: message}} = duplicate,
           "expected the duplicate (run_id, seq) insert to be rejected by SQLite"

    assert message =~ ~r/unique|constraint/i, "unexpected SQLite error for the duplicate seq: #{message}"
  end

  test "indexes support run, attempt, and seq lookups", %{db: db, migration_outcome: outcome} do
    for expected <- @expected_indexes do
      assert_table_exists(db, expected["table"], outcome)
      assert_index_exists(db, expected)
    end
  end

  test "JSON payload round-trips unknown fields", %{db: db, migration_outcome: outcome} do
    assert_table_exists(db, "run_events", outcome)

    run_id = insert_run(db)
    assert_event_ok(db, %{"run_id" => run_id, "attempt_id" => nil, "seq" => 1, "type" => "run.created"})

    {:ok, %{rows: [[stored]]}} =
      Exqlite.query(db, "SELECT payload FROM run_events ORDER BY seq LIMIT 1", [])

    assert is_binary(stored), "payload column must store the JSON text, got: #{inspect(stored)}"

    decoded =
      case Jason.decode(stored) do
        {:ok, value} -> value
        {:error, error} -> flunk("payload is not valid JSON: #{Exception.message(error)}")
      end

    assert decoded == @payload,
           "JSON payload lost information on round-trip:\nexpected: #{inspect(@payload)}\nactual:   #{inspect(decoded)}"
  end

  ## Schema assertions

  defp assert_table_exists(db, table, migration_outcome) do
    tables = introspect_tables(db)

    assert table in tables,
           "table #{inspect(table)} is missing from the migrated database " <>
             "(migrations: #{describe_migration_outcome(migration_outcome)})"
  end

  defp assert_fields(db, table, fields) do
    actual = introspect_columns(db, table)

    for {name, flags} <- fields do
      info = actual[name]

      assert info, "column #{inspect(table)}.#{inspect(name)} is missing, found: #{inspect(Map.keys(actual))}"

      if Keyword.get(flags, :required) do
        assert info["notnull"] in [1, "1"],
               "column #{inspect(table)}.#{inspect(name)} must be NOT NULL per the frozen contract"
      else
        assert info["notnull"] in [0, "0", nil],
               "column #{inspect(table)}.#{inspect(name)} must be nullable per the frozen contract"
      end

      if Keyword.get(flags, :pk) do
        assert info["pk"] in [1, "1"], "column #{inspect(table)}.#{inspect(name)} must be the primary key"
      end
    end
  end

  defp assert_foreign_keys(db, table, expected) do
    actual = introspect_foreign_keys(db, table)

    for {column, referenced_table, required: required?} <- expected do
      fk =
        Enum.find(actual, fn entry ->
          entry["from"] == column and entry["table"] == referenced_table
        end)

      assert fk, "expected #{inspect(table)}.#{inspect(column)} to be a foreign key to #{inspect(referenced_table)}"

      if required? do
        column_info = introspect_columns(db, table)[column]
        assert column_info["notnull"] in [1, "1"], "#{inspect(table)}.#{inspect(column)} must be NOT NULL"
      else
        column_info = introspect_columns(db, table)[column]

        assert column_info["notnull"] in [0, "0", nil],
               "#{inspect(table)}.#{inspect(column)} must stay nullable (run-level events have no attempt)"
      end
    end
  end

  defp assert_event_attempt_is_optional(db) do
    info = introspect_columns(db, "run_events")["attempt_id"]
    assert info, "column run_events.attempt_id is missing"
    assert info["notnull"] in [0, "0", nil], "run_events.attempt_id must be nullable"
  end

  defp assert_index_exists(db, %{"table" => table, "leading" => leading, "unique" => unique?}) do
    index =
      Enum.find(introspect_indexes(db, table), fn entry ->
        entry["leading"] == leading and (!unique? or entry["unique"])
      end)

    uniqueness = if unique?, do: "unique ", else: ""

    assert index,
           "expected a #{uniqueness}index on #{inspect(table)} covering #{inspect(leading)} " <>
             "for #{run_attempt_seq_lookup_note(leading)}, found: #{inspect(indexes_overview(db, table))}"
  end

  defp assert_unique_index(db, table, leading) do
    index =
      Enum.find(introspect_indexes(db, table), fn entry ->
        entry["leading"] == leading and entry["unique"]
      end)

    assert index,
           "expected a unique index on #{inspect(table)} covering #{inspect(leading)}; found: #{inspect(indexes_overview(db, table))}"
  end

  ## Behavioral helpers

  defp insert_run(db) do
    values = %{"tracker_ref" => "RES-337", "tracker_url" => "https://example.invalid/RES-337", "status" => "running"}
    insert_row(db, "runs", values)
  end

  defp insert_attempt(db, run_id) do
    values = %{"run_id" => run_id, "number" => 1, "started_at" => @timestamp}
    insert_row(db, "run_attempts", values)
  end

  defp assert_event_ok(db, values) do
    values = values |> Map.put_new("occurred_at", @timestamp) |> Map.put_new("source", "symphony")
    values = Map.put_new(values, "payload", Jason.encode!(@payload))
    insert_row(db, "run_events", values)
  end

  defp assert_event_fk_rejected(db, values) do
    values = values |> Map.put_new("occurred_at", @timestamp) |> Map.put_new("source", "symphony")
    values = Map.put_new(values, "payload", Jason.encode!(@payload))

    result =
      try do
        Exqlite.query(db, insert_sql("run_events", values), [])
      rescue
        error in Exqlite.Error -> {:error, error}
      end

    assert {:error, %Exqlite.Error{message: message}} = result,
           "expected the event insert with an unknown reference to be rejected by the foreign key"

    assert message =~ ~r/foreign key/i, "unexpected SQLite error for the event foreign key: #{message}"
  end

  defp insert_row(db, table, values) do
    columns = introspect_columns(db, table)
    values = ensure_id(columns, values)
    {:ok, _} = Exqlite.query(db, insert_sql(table, values), [])
    fetch_inserted_id(db, table, values)
  end

  defp ensure_id(columns, values) do
    info = columns["id"]
    assert info, "table has no id column"

    # A rowid alias (INTEGER PRIMARY KEY) auto-generates its value; any other
    # id column (e.g. TEXT) needs an explicit value because SQLite may accept
    # NULL into a non-integer primary key.
    rowid_alias? = integer_primary_key?(info)

    case {Map.get(values, "id"), rowid_alias?} do
      {nil, false} -> Map.put(values, "id", new_id())
      _ -> values
    end
  end

  defp integer_primary_key?(%{"pk" => pk, "type" => type}) do
    pk in [1, "1"] and is_binary(type) and String.downcase(type) =~ ~r/int/
  end

  defp insert_sql(table, values) do
    columns = Map.keys(values)
    quoted = Enum.map_join(columns, ", ", fn name -> "\"" <> name <> "\"" end)

    # Raw values must be SQL-quoted: nil becomes NULL, strings become quoted
    # literals (single quotes doubled), everything else is rendered verbatim.
    placeholders = Enum.map_join(Map.values(values), ", ", &sql_value/1)

    "INSERT INTO \"" <> table <> "\" (" <> quoted <> ") VALUES (" <> placeholders <> ")"
  end

  defp sql_value(nil), do: "NULL"
  defp sql_value(value) when is_integer(value), do: Integer.to_string(value)
  defp sql_value(value) when is_binary(value), do: "'" <> String.replace(value, "'", "''") <> "'"
  defp sql_value(value), do: sql_value(inspect(value))

  defp fetch_inserted_id(db, table, values) do
    case Map.get(values, "id") do
      id when not is_nil(id) ->
        id

      _ ->
        {:ok, %{rows: [[rowid]]}} = Exqlite.query(db, "SELECT last_insert_rowid()", [])
        refute rowid in [0, "0"], "could not resolve the generated id of the new #{table} row"
        rowid
    end
  end

  defp new_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  ## Introspection

  defp introspect_tables(db) do
    {:ok, %{rows: rows}} =
      Exqlite.query(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'", [])

    MapSet.new(Enum.flat_map(rows, & &1))
  end

  defp introspect_columns(db, table) do
    {:ok, %{rows: rows}} = Exqlite.query(db, "PRAGMA table_info(#{quote_ident(table)})", [])

    # PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
    for [_cid, name, type, notnull, default, pk] <- rows, into: %{} do
      {name, %{"type" => type, "notnull" => notnull, "dflt_value" => default, "pk" => pk}}
    end
  end

  defp introspect_foreign_keys(db, table) do
    {:ok, %{rows: rows}} = Exqlite.query(db, "PRAGMA foreign_key_list(#{quote_ident(table)})", [])

    # PRAGMA foreign_key_list columns: id, seq, table, from, to, on_update, on_delete, match
    for [_id, _seq, table_ref, from, _to | _] <- rows do
      %{"from" => from, "table" => table_ref}
    end
  end

  defp introspect_indexes(db, table) do
    {:ok, %{rows: index_rows}} = Exqlite.query(db, "PRAGMA index_list(#{quote_ident(table)})", [])

    # PRAGMA index_list columns: seqno, name, unique, origin, partial
    for [_seqno, name, unique | _] <- index_rows do
      {:ok, %{rows: info_rows}} = Exqlite.query(db, "PRAGMA index_info(#{quote_ident(name)})", [])

      # PRAGMA index_info columns: seqno, cid, name (rows are lists in exqlite 0.40.x)
      leading =
        info_rows
        |> Enum.sort_by(fn [seqno, _cid, _name] -> seqno end)
        |> Enum.map(fn [_seqno, _cid, name] -> name end)
        |> Enum.reject(&is_nil/1)

      %{"name" => name, "unique" => unique in [1, "1"], "leading" => leading}
    end
  end

  defp indexes_overview(db, table) do
    introspect_indexes(db, table)
    |> Enum.map(fn entry -> "#{entry["name"]}(#{Enum.join(entry["leading"], ", ")})" end)
  end

  defp quote_ident(name) do
    "\"" <> String.replace(name, "\"", "\"\"") <> "\""
  end

  defp run_attempt_seq_lookup_note(["run_id", "seq"]), do: "run and seq lookups"
  defp run_attempt_seq_lookup_note(["attempt_id"]), do: "attempt lookups"
  defp run_attempt_seq_lookup_note(["run_id"]), do: "run lookups"

  ## Migration bootstrap

  defp migrate_temp_db(db_path) do
    dir = Enum.find(@migrations_dirs, &File.dir?/1)

    case dir do
      nil ->
        :no_migrations_dir

      _ ->
        {:ok, _} = Repo.start_link(db_path: db_path)

        on_exit(fn ->
          try do
            Repo.stop()
          rescue
            _ -> :ok
          catch
            :exit, _reason -> :ok
          end
        end)

        try do
          _versions = Ecto.Migrator.run(Repo, Path.expand(dir), :up, all: true)
          :migrated
        rescue
          error -> {:migration_failed, Exception.message(error)}
        end
    end
  end

  defp describe_migration_outcome(:no_migrations_dir),
    do: "no migrations directory found under #{Enum.join(@migrations_dirs, " or ")}"

  defp describe_migration_outcome(:migrated), do: "migrations applied"

  defp describe_migration_outcome({:migration_failed, message}), do: "migrations failed: #{message}"

  # The temp DB name must stay unique across processes AND across VM runs
  # (System.unique_integer/1 only resets per VM), and a stale file from an
  # earlier run must never be reopened with its old contents.
  defp unique_temp_db_path do
    path =
      System.tmp_dir!()
      |> Path.join("symphony-run-store-contract-#{System.unique_integer([:positive])}-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}.db")

    if File.exists?(path) do
      unique_temp_db_path()
    else
      path
    end
  end
end

defmodule SymphonyElixir.ControlPlane.RunStoreSchemaContract.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_config, opts) do
    # Accept the project's `:db_path` convention; the SQLite3 adapter reads `:database`.
    # The migrator also inspects `Repo.config()` without that option, so fall back
    # to an already-present `:database`; the live pool is always started with one.
    database = Keyword.get(opts, :db_path) || Keyword.get(opts, :database)

    if is_nil(database) do
      {:ok, opts}
    else
      {:ok, Keyword.put(opts, :database, database)}
    end
  end
end
