defmodule SymphonyElixir.ControlPlane.Repo do
  @moduledoc """
  Ecto repo for the Symphony control plane. Uses SQLite via ecto_sqlite3.

  The default database path is in the user's Symphony state directory:
  $HOME/.local/share/symphony/symphony.db. Override via `:database`
  application env, or for testing via `Application.put_env`.
  """

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Returns the configured database file path. For an already-started Repo,
  queries the already-established `:database` config. Otherwise consults
  application env. Defaults to `~/.local/share/symphony/symphony.db`.
  """
  @spec db_path() :: String.t()
  def db_path do
    # First check if we already have a running repo instance holding its own path
    case Application.get_env(:symphony_elixir, __MODULE__) do
      opts when is_list(opts) ->
        case Keyword.get(opts, :database) do
          nil -> default_db_path()
          path when is_binary(path) -> path
        end

      _ ->
        default_db_path()
    end
  end

  defp default_db_path do
    home = System.user_home()

    case home do
      nil ->
        raise "Could not determine user home directory for default DB path"

      _ ->
        Path.join([home, ".local", "share", "symphony", "symphony.db"])
    end
  end
end
