defmodule SymphonyElixir.Pi.RPC do
  @moduledoc """
  Minimal client for the Pi coding agent RPC mode (`pi --mode rpc`).

  Pi reads commands as JSON lines on stdin and streams events plus command
  responses as JSON lines on stdout. One Pi process serves every Symphony
  continuation turn in a worker attempt, and a turn only ends once Pi reports
  `agent_settled`, so retries and compaction inside Pi stay inside that turn.
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger
  alias SymphonyElixir.{Config, SSH, Tracker, WorkspaceGuard}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @stream_update_interval_ms 1_000
  @prompt_request_id "symphony-prompt"
  @state_request_id "symphony-get-state"
  @stats_request_id "symphony-session-stats"

  # Events worth showing on the dashboard. Streaming deltas are handled
  # separately because they arrive far too often to forward one by one.
  @forwarded_events ~w(
    agent_start
    turn_start
    turn_end
    agent_end
    tool_execution_start
    tool_execution_end
    compaction_start
    compaction_end
    auto_retry_start
    auto_retry_end
    extension_error
  )

  @stream_event "message_update"
  @dialog_ui_methods ~w(select confirm input editor)
  @error_stream_pattern ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i

  @type session :: %{
          port: port(),
          metadata: map(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          pi_session_id: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- WorkspaceGuard.validate(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host) do
      metadata = port_metadata(port, worker_host)

      case fetch_pi_session_id(port) do
        {:ok, pi_session_id} ->
          {:ok,
           %{
             port: port,
             metadata: metadata,
             workspace: expanded_workspace,
             worker_host: worker_host,
             pi_session_id: pi_session_id
           }}

        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_number = Keyword.get(opts, :turn_number, 1)
    session_id = session_id(session, turn_number)

    with :ok <-
           send_command(session.port, %{
             "id" => @prompt_request_id,
             "type" => "prompt",
             "message" => prompt
           }) do
      Logger.info("Pi session started for #{issue_context(issue)} session_id=#{session_id}")

      emit_message(
        on_message,
        :session_started,
        %{
          session_id: session_id,
          pi_session_id: session.pi_session_id,
          turn_number: turn_number
        },
        session.metadata
      )

      case await_turn_settled(session, on_message) do
        {:ok, result} ->
          Logger.info("Pi session completed for #{issue_context(issue)} session_id=#{session_id}")

          emit_session_stats(session, on_message)

          {:ok,
           %{
             result: result,
             session_id: session_id,
             pi_session_id: session.pi_session_id,
             turn_number: turn_number
           }}

        {:error, reason} ->
          Logger.warning("Pi session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

          emit_message(
            on_message,
            :turn_ended_with_error,
            %{session_id: session_id, reason: reason},
            session.metadata
          )

          {:error, reason}
      end
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp await_turn_settled(session, on_message) do
    receive_loop(session, on_message, Config.settings!().pi.turn_timeout_ms, "", nil)
  end

  defp receive_loop(session, on_message, timeout_ms, pending_line, last_stream_ms) do
    case await_port_message(session.port, timeout_ms) do
      {:data, {:eol, chunk}} ->
        handle_stream_line(session, on_message, timeout_ms, pending_line <> to_string(chunk), last_stream_ms)

      {:data, {:noeol, chunk}} ->
        receive_loop(
          session,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          last_stream_ms
        )

      {:exit_status, status} ->
        {:error, {:port_exit, status}}

      :turn_timeout ->
        {:error, :turn_timeout}
    end
  end

  defp handle_stream_line(session, on_message, timeout_ms, line, last_stream_ms) do
    case Jason.decode(line) do
      {:ok, %{"type" => "agent_settled"} = event} ->
        emit_pi_event(on_message, event, line, session.metadata)
        {:ok, %{event: "agent_settled"}}

      {:ok, %{"type" => "response"} = response} ->
        case Map.get(response, "success") do
          true ->
            receive_loop(session, on_message, timeout_ms, "", last_stream_ms)

          _ ->
            {:error, {:pi_command_failed, Map.get(response, "command"), Map.get(response, "error")}}
        end

      {:ok, %{"type" => "extension_ui_request"} = request} ->
        answer_extension_ui(session.port, request)
        receive_loop(session, on_message, timeout_ms, "", last_stream_ms)

      {:ok, %{"type" => type} = event} when is_binary(type) ->
        last_stream_ms = maybe_emit_pi_event(on_message, event, line, session.metadata, last_stream_ms)
        receive_loop(session, on_message, timeout_ms, "", last_stream_ms)

      {:ok, _payload} ->
        receive_loop(session, on_message, timeout_ms, "", last_stream_ms)

      {:error, _reason} ->
        log_non_json_stream_line(line, "turn stream")
        receive_loop(session, on_message, timeout_ms, "", last_stream_ms)
    end
  end

  defp maybe_emit_pi_event(on_message, %{"type" => @stream_event} = event, line, metadata, last_stream_ms) do
    now_ms = System.monotonic_time(:millisecond)

    if is_nil(last_stream_ms) or now_ms - last_stream_ms >= @stream_update_interval_ms do
      emit_pi_event(on_message, event, line, metadata)
      now_ms
    else
      last_stream_ms
    end
  end

  defp maybe_emit_pi_event(on_message, %{"type" => type} = event, line, metadata, last_stream_ms) do
    if type in @forwarded_events do
      emit_pi_event(on_message, event, line, metadata)
    end

    last_stream_ms
  end

  defp emit_pi_event(on_message, event, raw, metadata) do
    emit_message(
      on_message,
      :notification,
      %{payload: pi_event_payload(event), raw: raw},
      metadata
    )
  end

  # Keep dashboard payloads small: Pi events can carry whole messages, file
  # contents, or tool results that are far too large to keep as last activity.
  defp pi_event_payload(%{"type" => "tool_execution_start"} = event) do
    %{"method" => "pi/tool_execution_start", "toolName" => Map.get(event, "toolName")}
  end

  defp pi_event_payload(%{"type" => "tool_execution_end"} = event) do
    %{
      "method" => "pi/tool_execution_end",
      "toolName" => Map.get(event, "toolName"),
      "isError" => Map.get(event, "isError")
    }
  end

  defp pi_event_payload(%{"type" => "compaction_start"} = event) do
    %{"method" => "pi/compaction_start", "reason" => Map.get(event, "reason")}
  end

  defp pi_event_payload(%{"type" => "compaction_end"} = event) do
    %{
      "method" => "pi/compaction_end",
      "reason" => Map.get(event, "reason"),
      "aborted" => Map.get(event, "aborted"),
      "willRetry" => Map.get(event, "willRetry")
    }
  end

  defp pi_event_payload(%{"type" => "auto_retry_start"} = event) do
    %{
      "method" => "pi/auto_retry_start",
      "attempt" => Map.get(event, "attempt"),
      "maxAttempts" => Map.get(event, "maxAttempts"),
      "errorMessage" => Map.get(event, "errorMessage")
    }
  end

  defp pi_event_payload(%{"type" => "auto_retry_end"} = event) do
    %{
      "method" => "pi/auto_retry_end",
      "success" => Map.get(event, "success"),
      "attempt" => Map.get(event, "attempt"),
      "finalError" => Map.get(event, "finalError")
    }
  end

  defp pi_event_payload(%{"type" => "agent_end"} = event) do
    %{"method" => "pi/agent_end", "willRetry" => Map.get(event, "willRetry")}
  end

  defp pi_event_payload(%{"type" => "extension_error"} = event) do
    %{
      "method" => "pi/extension_error",
      "event" => Map.get(event, "event"),
      "error" => Map.get(event, "error")
    }
  end

  defp pi_event_payload(%{"type" => @stream_event} = event) do
    %{
      "method" => "pi/message_update",
      "deltaType" => get_in(event, ["assistantMessageEvent", "type"])
    }
  end

  defp pi_event_payload(%{"type" => type}), do: %{"method" => "pi/" <> type}

  defp emit_session_stats(session, on_message) do
    with {:ok, %{"tokens" => tokens}} when is_map(tokens) <-
           request_command_data(session.port, @stats_request_id, "get_session_stats"),
         %{} = total <- absolute_token_usage(tokens) do
      emit_message(
        on_message,
        :notification,
        %{
          payload: %{
            "method" => "pi/session_stats",
            "tokens" => tokens,
            "params" => %{"tokenUsage" => %{"total" => total}}
          },
          raw: Jason.encode!(%{"type" => "pi/session_stats", "tokens" => tokens}),
          usage: tokens
        },
        session.metadata
      )
    else
      _ -> :ok
    end
  end

  # Pi reports session cumulative usage; mirror the Codex tokenUsage shape so
  # the existing orchestrator accounting keeps working. The orchestrator reads
  # absolute totals from `params.tokenUsage.total`, so the update carries them
  # in that shape instead of a Pi-specific one.
  defp absolute_token_usage(tokens) do
    %{
      "inputTokens" => token_count(tokens, ["input", "inputTokens"]),
      "outputTokens" => token_count(tokens, ["output", "outputTokens"]),
      "totalTokens" => token_count(tokens, ["total", "totalTokens"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      usage when map_size(usage) > 0 -> usage
      _ -> nil
    end
  end

  defp token_count(tokens, keys) when is_map(tokens) do
    Enum.find_value(keys, fn key ->
      case Map.get(tokens, key) do
        value when is_integer(value) -> value
        _ -> nil
      end
    end)
  end

  defp fetch_pi_session_id(port) do
    with {:ok, %{} = state} <- request_command_data(port, @state_request_id, "get_state") do
      {:ok, Map.get(state, "sessionId")}
    end
  end

  defp request_command_data(port, request_id, command) do
    with :ok <- send_command(port, %{"id" => request_id, "type" => command}) do
      await_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
    end
  end

  defp await_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_response_line(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:data, {:noeol, chunk}}} ->
        await_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response_line(port, request_id, timeout_ms, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "response", "id" => ^request_id} = response} ->
        case Map.get(response, "success") do
          true -> {:ok, Map.get(response, "data")}
          _ -> {:error, {:pi_command_failed, Map.get(response, "command"), Map.get(response, "error")}}
        end

      {:ok, _ignored} ->
        await_response(port, request_id, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_stream_line(line, "response stream")
        await_response(port, request_id, timeout_ms, "")
    end
  end

  defp answer_extension_ui(port, %{"id" => id, "method" => method})
       when is_binary(id) and method in @dialog_ui_methods do
    # Nothing can answer a dialog in an unattended run, so dismiss it instead
    # of letting Pi block forever.
    send_command(port, %{"type" => "extension_ui_response", "id" => id, "cancelled" => true})
  end

  defp answer_extension_ui(_port, _request), do: :ok

  defp start_port(workspace, nil) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(local_launch_command())],
            cd: String.to_charlist(workspace),
            env: tracker_secret_port_env(),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host) when is_binary(worker_host) do
    SSH.start_port(worker_host, remote_launch_command(workspace), line: @port_line_bytes)
  end

  defp local_launch_command do
    [tracker_secret_unset_command(), "exec #{Config.settings!().pi.command}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(),
      "exec #{Config.settings!().pi.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  # The agent gets its own tracker credentials, so Symphony's tracker token
  # never needs to reach the Pi child process.
  defp tracker_secret_port_env do
    tracker_secret_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command do
    case tracker_secret_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp tracker_secret_names do
    Tracker.secret_environment_names()
    |> Enum.filter(&valid_environment_name?/1)
  end

  defp valid_environment_name?(name) do
    is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp session_id(%{pi_session_id: pi_session_id}, turn_number)
       when is_binary(pi_session_id) and pi_session_id != "" do
    "#{pi_session_id}-t#{turn_number}"
  end

  defp session_id(_session, turn_number), do: "pi-t#{turn_number}"

  defp send_command(port, command) when is_map(command) do
    Port.command(port, Jason.encode!(command) <> "\n")
    :ok
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  defp await_port_message(port, timeout_ms) when timeout_ms <= 0 do
    receive do
      {^port, {:data, data}} -> {:data, data}
      {^port, {:exit_status, status}} -> {:exit_status, status}
    end
  end

  defp await_port_message(port, timeout_ms) do
    receive do
      {^port, {:data, data}} -> {:data, data}
      {^port, {:exit_status, status}} -> {:exit_status, status}
    after
      timeout_ms -> :turn_timeout
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, @error_stream_pattern) do
        Logger.warning("Pi #{stream_label} output: #{text}")
      else
        Logger.debug("Pi #{stream_label} output: #{text}")
      end
    end
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
