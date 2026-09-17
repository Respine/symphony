defmodule SymphonyElixir.ControlPlane.Repo do
  require Logger

  use Ecto.Repo, otp_app: :symphony_elixir, adapter: Ecto.Adapters.SQLite3

  @default_db Path.expand("~/.symphony/db/symphony.db")

  @doc """
  Returns the path to the SQLite database file.

  Reads the configured `:database` from the `:symphony_elixir` application config
  for the Repo's ecto config. When not set, defaults to `~/.symphony/db/symphony.db`.
  """
  @spec database_path() :: binary()
  def database_path do
    config_path =
      Application.get_env(:symphony_elixir, __MODULE__, [])
      |> Keyword.get(:database, @default_db)

    config_path
  end

  @impl true
  def init(_type, config) do
    # Inject the configured database destination path into Ecto config
    database = resolve_database_path(config)

    config = Keyword.put(config, :database, database)

    # Ensure parent directory exists on first start (fresh environment support)
    db_dir = Path.dirname(database)

    if !File.exists?(db_dir) do
      case File.mkdir_p(db_dir) do
        :ok -> :ok
        {:error, _reason} -> Logger.debug("Could not create DB directory: #{db_dir}")
      end
    end

    {:ok, config}
  end

  defp resolve_database_path(config) do
    config
    |> Keyword.get(:database, @default_db)
  end
end
