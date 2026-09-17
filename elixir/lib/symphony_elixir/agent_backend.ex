defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Boundary between the agent runner and a concrete agent CLI.

  A backend owns one agent process for the lifetime of a worker attempt:
  `start_session/2` launches it in the issue workspace, `run_turn/4` runs one
  Symphony turn and streams updates through `on_message`, and `stop_session/1`
  shuts it down. Continuation turns reuse the same session.
  """

  alias SymphonyElixir.Tracker.Issue

  @type session :: term()

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), Issue.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok
end
