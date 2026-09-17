defmodule SymphonyElixir.PiRpcTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pi.RPC

  @issue %Issue{
    id: "issue-pi",
    identifier: "MT-900",
    title: "Pi backend",
    description: "Run the Pi backend",
    state: "In Progress",
    url: "https://example.org/issues/MT-900",
    labels: [],
    dispatchable: true
  }

  test "pi backend reuses one pi process across turns and reports usage" do
    test_root = tmp_root("pi-backend-lifecycle")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-900")
      pi_binary = Path.join(test_root, "fake-pi")
      trace_file = Path.join(test_root, "pi.trace")

      File.mkdir_p!(workspace)
      write_executable!(pi_binary, pi_script())
      System.put_env("SYMP_PI_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_PI_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "pi",
        pi_command: "#{pi_binary} --mode rpc",
        pi_turn_timeout_ms: 5_000
      )

      parent = self()
      on_message = fn message -> send(parent, {:pi_update, message}) end

      assert {:ok, session} = RPC.start_session(workspace)
      assert session.pi_session_id == "pi-session-1"

      assert {:ok, first_turn} =
               RPC.run_turn(session, "first prompt", @issue,
                 on_message: on_message,
                 turn_number: 1
               )

      assert first_turn.session_id == "pi-session-1-t1"

      assert {:ok, second_turn} =
               RPC.run_turn(session, "second prompt", @issue,
                 on_message: on_message,
                 turn_number: 2
               )

      assert second_turn.session_id == "pi-session-1-t2"
      assert :ok = RPC.stop_session(session)

      trace = File.read!(trace_file) |> String.split("\n", trim: true)
      assert Enum.count(trace, &String.starts_with?(&1, "RUN:")) == 1
      assert Enum.count(trace, &String.contains?(&1, ~s("type":"get_state"))) == 1
      assert Enum.count(trace, &String.contains?(&1, ~s("type":"prompt"))) == 2
      assert Enum.any?(trace, &String.contains?(&1, ~s("type":"extension_ui_response")))
      assert Enum.any?(trace, &String.contains?(&1, ~s("cancelled":true)))

      assert_receive {:pi_update,
                      %{
                        event: :session_started,
                        session_id: "pi-session-1-t1",
                        pi_session_id: "pi-session-1",
                        turn_number: 1
                      }}

      assert_receive {:pi_update, %{event: :notification, payload: %{"method" => "pi/agent_start"}}}

      assert_receive {:pi_update,
                      %{
                        event: :notification,
                        payload: %{
                          "method" => "pi/tool_execution_end",
                          "toolName" => "bash",
                          "isError" => false
                        }
                      }}

      assert_receive {:pi_update,
                      %{
                        event: :notification,
                        payload: %{"method" => "pi/agent_end", "willRetry" => false}
                      }}

      assert_receive {:pi_update, %{event: :notification, payload: %{"method" => "pi/agent_settled"}}}

      assert_receive {:pi_update,
                      %{
                        event: :notification,
                        usage: usage,
                        payload: %{
                          "method" => "pi/session_stats",
                          "params" => %{"tokenUsage" => %{"total" => total_tokens}}
                        }
                      }}

      assert usage == %{
               "input" => 120,
               "output" => 30,
               "cacheRead" => 0,
               "cacheWrite" => 0,
               "total" => 150
             }

      assert total_tokens == %{
               "inputTokens" => 120,
               "outputTokens" => 30,
               "totalTokens" => 150
             }

      assert_receive {:pi_update, %{event: :session_started, session_id: "pi-session-1-t2"}}
    after
      File.rm_rf(test_root)
    end
  end

  test "pi backend throttles streaming updates instead of forwarding every delta" do
    test_root = tmp_root("pi-backend-stream-throttle")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-900")
      pi_binary = Path.join(test_root, "fake-pi")

      File.mkdir_p!(workspace)
      write_executable!(pi_binary, pi_script(message_updates: 20))

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "pi",
        pi_command: "#{pi_binary} --mode rpc",
        pi_turn_timeout_ms: 5_000
      )

      parent = self()
      on_message = fn message -> send(parent, {:pi_update, message}) end

      assert {:ok, session} = RPC.start_session(workspace)
      assert {:ok, _turn} = RPC.run_turn(session, "prompt", @issue, on_message: on_message)
      assert :ok = RPC.stop_session(session)

      stream_updates = collect_pi_updates(:pi_update, [])

      stream_count =
        Enum.count(stream_updates, fn update ->
          match?(%{event: :notification, payload: %{"method" => "pi/message_update"}}, update)
        end)

      assert stream_count >= 1
      assert stream_count < 20
    after
      File.rm_rf(test_root)
    end
  end

  test "pi backend fails the turn when pi stops streaming" do
    test_root = tmp_root("pi-backend-turn-timeout")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-900")
      pi_binary = Path.join(test_root, "fake-pi")

      File.mkdir_p!(workspace)
      write_executable!(pi_binary, pi_script(silent_turn: true))

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "pi",
        pi_command: "#{pi_binary} --mode rpc",
        pi_turn_timeout_ms: 400
      )

      assert {:ok, session} = RPC.start_session(workspace)
      assert {:error, :turn_timeout} = RPC.run_turn(session, "prompt", @issue)
      assert :ok = RPC.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "pi backend fails the turn when the pi process exits" do
    test_root = tmp_root("pi-backend-crash")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-900")
      pi_binary = Path.join(test_root, "fake-pi")

      File.mkdir_p!(workspace)
      write_executable!(pi_binary, pi_script(crash_after_prompt: 3))

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "pi",
        pi_command: "#{pi_binary} --mode rpc",
        pi_turn_timeout_ms: 5_000
      )

      assert {:ok, session} = RPC.start_session(workspace)
      assert {:error, {:port_exit, 3}} = RPC.run_turn(session, "prompt", @issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "pi backend fails to start when the pi command cannot stay up" do
    test_root = tmp_root("pi-backend-startup-failure")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-900")
      pi_binary = Path.join(test_root, "fake-pi")

      File.mkdir_p!(workspace)
      write_executable!(pi_binary, "#!/bin/sh\necho 'pi is not configured' >&2\nexit 2\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "pi",
        pi_command: "#{pi_binary} --mode rpc"
      )

      assert {:error, {:port_exit, 2}} = RPC.start_session(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "pi backend refuses to run outside the workspace root" do
    test_root = tmp_root("pi-backend-cwd-guard")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      pi_binary = Path.join(test_root, "fake-pi")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      write_executable!(pi_binary, pi_script())

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "pi",
        pi_command: "#{pi_binary} --mode rpc"
      )

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               RPC.start_session(workspace_root)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               RPC.start_session(outside_workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "pi session stats update feeds the existing orchestrator token accounting" do
    test_root = tmp_root("pi-backend-token-accounting")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-900")
      pi_binary = Path.join(test_root, "fake-pi")

      File.mkdir_p!(workspace)
      write_executable!(pi_binary, pi_script())

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "pi",
        pi_command: "#{pi_binary} --mode rpc",
        pi_turn_timeout_ms: 5_000
      )

      parent = self()
      on_message = fn message -> send(parent, {:pi_update, message}) end

      assert {:ok, session} = RPC.start_session(workspace)
      assert {:ok, _turn} = RPC.run_turn(session, "prompt", @issue, on_message: on_message)
      assert :ok = RPC.stop_session(session)

      stats_update =
        collect_pi_updates(:pi_update, [])
        |> Enum.find(&match?(%{payload: %{"method" => "pi/session_stats"}}, &1))

      assert is_map(stats_update)

      orchestrator_name = Module.concat(__MODULE__, :PiTokenOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      initial_state = :sys.get_state(pid)
      started_at = DateTime.utc_now()

      running_entry = %{
        pid: self(),
        ref: make_ref(),
        identifier: @issue.identifier,
        issue: @issue,
        session_id: nil,
        turn_count: 0,
        last_codex_message: nil,
        last_codex_timestamp: nil,
        last_codex_event: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        codex_last_reported_input_tokens: 0,
        codex_last_reported_output_tokens: 0,
        codex_last_reported_total_tokens: 0,
        started_at: started_at
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{@issue.id => running_entry})
        |> Map.put(:claimed, MapSet.put(initial_state.claimed, @issue.id))
      end)

      send(pid, {:codex_worker_update, @issue.id, stats_update})

      assert %{running: [snapshot_entry]} = GenServer.call(pid, :snapshot)
      assert snapshot_entry.codex_input_tokens == 120
      assert snapshot_entry.codex_output_tokens == 30
      assert snapshot_entry.codex_total_tokens == 150
      assert snapshot_entry.last_codex_event == :notification

      # Pi reports session cumulative usage, so a repeated report must not
      # double count tokens in the dashboard totals.
      send(pid, {:codex_worker_update, @issue.id, stats_update})

      assert %{running: [snapshot_entry]} = GenServer.call(pid, :snapshot)
      assert snapshot_entry.codex_input_tokens == 120
      assert snapshot_entry.codex_output_tokens == 30
      assert snapshot_entry.codex_total_tokens == 150
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner drives pi turns when agent.kind is pi" do
    test_root = tmp_root("pi-backend-agent-runner")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      pi_binary = Path.join(test_root, "fake-pi")
      trace_file = Path.join(test_root, "pi.trace")

      File.mkdir_p!(workspace_root)
      write_executable!(pi_binary, pi_script())
      System.put_env("SYMP_PI_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_PI_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "pi",
        pi_command: "#{pi_binary} --mode rpc",
        pi_turn_timeout_ms: 5_000,
        max_turns: 3
      )

      parent = self()
      fetch_count = :counters.new(1, [])

      state_fetcher = fn [_issue_id] ->
        :counters.add(fetch_count, 1, 1)
        attempt = :counters.get(fetch_count, 1)
        send(parent, {:issue_state_fetch, attempt})

        state = if attempt == 1, do: "In Progress", else: "Done"

        {:ok, [%{@issue | state: state}]}
      end

      assert :ok = AgentRunner.run(@issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}

      trace = File.read!(trace_file) |> String.split("\n", trim: true)
      assert_receive {:issue_state_fetch, 2}

      assert Enum.count(trace, &String.starts_with?(&1, "RUN:")) == 1

      prompts =
        trace
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["type"] == "prompt"))
        |> Enum.map(& &1["message"])

      assert length(prompts) == 2
      assert Enum.at(prompts, 0) =~ "You are an agent for this repository."
      assert Enum.at(prompts, 1) =~ "Continuation guidance"
    after
      File.rm_rf(test_root)
    end
  end

  defp collect_pi_updates(tag, acc) do
    receive do
      {^tag, message} -> collect_pi_updates(tag, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp tmp_root(label) do
    Path.join(System.tmp_dir!(), "symphony-elixir-#{label}-#{System.unique_integer([:positive])}")
  end

  defp write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  defp pi_script(opts \\ []) do
    message_updates = Keyword.get(opts, :message_updates, 2)
    silent_turn? = Keyword.get(opts, :silent_turn, false)
    crash_after_prompt = Keyword.get(opts, :crash_after_prompt, nil)

    [
      "#!/bin/sh",
      ~s(trace_file="${SYMP_PI_TRACE:-/tmp/pi.trace}"),
      ~s(printf 'RUN:%s\\n' "$$" >> "$trace_file"),
      "",
      "while IFS= read -r line; do",
      ~s(  printf 'JSON:%s\\n' "$line" >> "$trace_file"),
      ~s(  case "$line" in),
      "    *get_session_stats*)",
      ~s(      printf '%s\\n' '{"id":"symphony-session-stats","type":"response","command":"get_session_stats","success":true,"data":{"sessionId":"pi-session-1","tokens":{"input":120,"output":30,"cacheRead":0,"cacheWrite":0,"total":150}}}'),
      "      ;;",
      "    *get_state*)",
      ~s(      printf '%s\\n' '{"id":"symphony-get-state","type":"response","command":"get_state","success":true,"data":{"sessionId":"pi-session-1","isStreaming":false,"messageCount":0}}'),
      "      ;;",
      "    *prompt*)",
      ~s(      printf '%s\\n' '{"id":"symphony-prompt","type":"response","command":"prompt","success":true}'),
      ~s(      printf '%s\\n' '{"type":"agent_start"}'),
      ~s(      printf '%s\\n' '{"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"Allow?","timeout":50}'),
      message_update_lines(message_updates),
      turn_body(silent_turn?, crash_after_prompt),
      "      ;;",
      "  esac",
      "done"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp message_update_lines(0), do: nil

  defp message_update_lines(count) do
    1..count
    |> Enum.map_join("\n", fn _index ->
      ~s(      printf '%s\\n' '{"type":"message_update","usage":{"input":1856,"output":46,"totalTokens":1902},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"streaming"}}')
    end)
  end

  defp turn_body(true, _crash_after_prompt), do: "      sleep 30"

  defp turn_body(_silent_turn?, crash_after_prompt) when is_integer(crash_after_prompt) do
    "      exit #{crash_after_prompt}"
  end

  defp turn_body(_silent_turn?, _crash_after_prompt) do
    [
      ~s(      printf '%s\\n' '{"type":"tool_execution_start","toolCallId":"call-1","toolName":"bash","args":{"command":"ls"}}'),
      ~s(      printf '%s\\n' '{"type":"tool_execution_end","toolCallId":"call-1","toolName":"bash","isError":false,"result":{"content":[]}}'),
      ~s(      printf '%s\\n' '{"type":"agent_end","messages":[{"role":"assistant"}],"willRetry":false}'),
      ~s(      printf '%s\\n' '{"type":"agent_settled"}')
    ]
    |> Enum.join("\n")
  end
end
