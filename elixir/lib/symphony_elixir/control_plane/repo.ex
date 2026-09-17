defmodule SymphonyElixir.ControlPlane.Repo do
  use Ecto.Repo, otp_app: :symphony_elixir, adapter: Ecto.Adapters.SQLite3

  @doc """
  Returns the path to the SQLite database file.

  Reads the configured `:db_path` from the `:symphony_elixir` application config.
  When the path contains a leading `~` it is expanded to the user's home directory.
  """
  @spec database_path() :: binary()
  def database_path do
    path =
      Application.get_env(:symphony_elixir, :db_path, "symphony.db")

    if String.starts_with?(path, "~") do
      System.user_home!() <> String.slice(path, 1, String.length(path) - 1)
    else
      path
    end
  end
end
