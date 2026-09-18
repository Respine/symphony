defmodule SymphonyElixir.ControlPlane.Repo do
  require Logger

  use Ecto.Repo, otp_app: :symphony_elixir, adapter: Ecto.Adapters.SQLite3

  @default_db Path.expand("~/.symphony/db/symphony.db")

  @doc """
  Returns the path to the SQLite database file.
  """
  @spec database_path() :: binary()
  def database_path do
    config = Application.get_env(:symphony_elixir, SymphonyElixir.ControlPlane.Repo, [])
    IO.puts("  [debug] database_path(): config = #{inspect(config)}")
    Keyword.get(config, :database, @default_db)
  end

  @impl true
  def init(_type, config) do
    database = resolve_database_path(config)
    config = Keyword.put(config, :database, database)

    if !File.exists?(Path.dirname(database)) do
      File.mkdir_p!(Path.dirname(database))
    end

    {:ok, config}
  end

  defp resolve_database_path(config) do
    Keyword.get(config, :database) || database_path()
  end
end
