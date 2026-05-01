defmodule SymphonyElixir.ProjectIssuePlannerTest do
  use SymphonyElixir.TestSupport

  import Plug.Conn

  alias SymphonyElixir.ProjectIssuePlanner

  defmodule FakePlannerOpenCodeState do
    use Agent

    def start_link(opts) do
      Agent.start_link(fn ->
        %{
          test_pid: Keyword.fetch!(opts, :test_pid),
          plan: Keyword.fetch!(opts, :plan),
          subscribers: MapSet.new()
        }
      end)
    end

    def plan(state), do: Agent.get(state, & &1.plan)
    def subscribe(state, pid), do: Agent.update(state, &Map.put(&1, :subscribers, MapSet.put(&1.subscribers, pid)))

    def broadcast(state, type, properties) do
      subscribers = Agent.get(state, &MapSet.to_list(&1.subscribers))

      Enum.each(subscribers, fn subscriber ->
        send(subscriber, {:fake_opencode_event, type, properties})
      end)
    end

    def notify(state, message) do
      state
      |> Agent.get(& &1.test_pid)
      |> send({:fake_planner_opencode_request, message})
    end
  end

  defmodule FakePlannerOpenCodePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      state = Keyword.fetch!(opts, :state)

      case {conn.method, String.split(conn.request_path, "/", trim: true)} do
        {"GET", ["global", "health"]} ->
          json(conn, 200, %{"healthy" => true})

        {"GET", ["global", "event"]} ->
          stream_events(conn, state)

        {"POST", ["session"]} ->
          body = read_json_body!(conn)
          FakePlannerOpenCodeState.notify(state, {:session_create, body})
          json(conn, 200, %{"id" => "planner-session"})

        {"POST", ["session", session_id, "message"]} ->
          body = read_json_body!(conn)
          FakePlannerOpenCodeState.notify(state, {:message_post, session_id, body})
          FakePlannerOpenCodeState.broadcast(state, "message.updated", %{"info" => %{"sessionID" => session_id}})

          json(conn, 200, %{
            "id" => "planner-message",
            "info" => %{
              "id" => "planner-message",
              "sessionID" => session_id,
              "structured_output" => FakePlannerOpenCodeState.plan(state)
            }
          })

        _ ->
          send_resp(conn, 404, "not found")
      end
    end

    defp stream_events(conn, state) do
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      FakePlannerOpenCodeState.subscribe(state, self())
      wait_for_disconnect(conn)
    end

    defp wait_for_disconnect(conn) do
      receive do
        :close -> conn
      after
        30_000 -> conn
      end
    end

    defp read_json_body!(conn) do
      {:ok, body, _conn} = read_body(conn)

      case body do
        "" -> %{}
        payload -> Jason.decode!(payload)
      end
    end

    defp json(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  test "validates a complete ordered plan" do
    issues = [issue("issue-a"), issue("issue-b")]

    plan = %{
      "schema_version" => 1,
      "project_key" => "id:project-1",
      "batches" => [
        %{"parallel_group" => 1, "issue_ids" => ["issue-b", "issue-a"], "reason" => "safe order"}
      ],
      "defer_issue_ids" => []
    }

    assert {:ok, ["issue-b", "issue-a"]} = ProjectIssuePlanner.validate_plan("id:project-1", issues, plan)
  end

  test "validates plans encoded as JSON" do
    issues = [issue("issue-a")]

    plan =
      Jason.encode!(%{
        "schema_version" => 1,
        "project_key" => "id:project-1",
        "batches" => [%{"parallel_group" => 1, "issue_ids" => ["issue-a"], "reason" => "only issue"}],
        "defer_issue_ids" => []
      })

    assert {:ok, ["issue-a"]} = ProjectIssuePlanner.validate_plan("id:project-1", issues, plan)
  end

  test "rejects malformed JSON" do
    assert {:error, {:invalid_plan_json, _reason}} =
             ProjectIssuePlanner.validate_plan("id:project-1", [issue("issue-a")], "not-json")
  end

  test "rejects wrong project keys" do
    plan = valid_plan(["issue-a"], project_key: "id:other-project")

    assert {:error, {:project_key_mismatch, "id:project-1", "id:other-project"}} =
             ProjectIssuePlanner.validate_plan("id:project-1", [issue("issue-a")], plan)
  end

  test "rejects unknown issue ids" do
    plan = valid_plan(["issue-a", "issue-missing"])

    assert {:error, {:unknown_issue_ids, ["issue-missing"]}} =
             ProjectIssuePlanner.validate_plan("id:project-1", [issue("issue-a")], plan)
  end

  test "rejects duplicate issue ids" do
    plan = valid_plan(["issue-a", "issue-a"])

    assert {:error, {:duplicate_issue_ids, ["issue-a"]}} =
             ProjectIssuePlanner.validate_plan("id:project-1", [issue("issue-a")], plan)
  end

  test "rejects incomplete issue coverage" do
    plan = valid_plan(["issue-a"])

    assert {:error, {:missing_issue_ids, ["issue-b"]}} =
             ProjectIssuePlanner.validate_plan("id:project-1", [issue("issue-a"), issue("issue-b")], plan)
  end

  test "runs OpenCode planner and extracts structured output order" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-project-planner-opencode-#{System.unique_integer([:positive])}"
      )

    plan = valid_plan(["issue-b", "issue-a"])

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      server = start_fake_planner_opencode_server!(plan)
      launcher = write_opencode_launcher_script!(test_root, server.base_url)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        opencode_command: launcher,
        opencode_agent: "sisyphus"
      )

      assert {:ok, ["issue-b", "issue-a"]} =
               ProjectIssuePlanner.plan_project_issues("id:project-1", [issue("issue-a"), issue("issue-b")])

      assert_receive {:fake_planner_opencode_request, {:session_create, %{"title" => title}}}, 1_000
      assert is_binary(title)

      assert_receive {:fake_planner_opencode_request,
                      {:message_post, "planner-session",
                       %{
                         "agent" => <<0xE2, 0x80, 0x8B>> <> "Sisyphus - Ultraworker",
                         "format" => %{"type" => "json_schema", "schema" => %{}},
                         "parts" => [%{"type" => "text", "text" => prompt_text}]
                       }}},
                     1_000

      assert prompt_text =~ "Project key: id:project-1"
      assert prompt_text =~ "issue-a"
      assert prompt_text =~ "issue-b"
    after
      File.rm_rf(test_root)
    end
  end

  defp valid_plan(issue_ids, opts \\ []) do
    %{
      "schema_version" => 1,
      "project_key" => Keyword.get(opts, :project_key, "id:project-1"),
      "batches" => [%{"parallel_group" => 1, "issue_ids" => issue_ids, "reason" => "test"}],
      "defer_issue_ids" => []
    }
  end

  defp issue(id) do
    %Issue{id: id, identifier: String.upcase(id), title: id, state: "Todo", project_id: "project-1"}
  end

  defp start_fake_planner_opencode_server!(plan) do
    {:ok, state} = start_supervised({FakePlannerOpenCodeState, test_pid: self(), plan: plan})
    bandit = start_supervised!({Bandit, plug: {FakePlannerOpenCodePlug, state: state}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    %{base_url: "http://127.0.0.1:#{port}", state: state}
  end

  defp write_opencode_launcher_script!(test_root, base_url) do
    launcher = Path.join(test_root, "fake-opencode-planner.sh")

    File.write!(launcher, """
    #!/bin/sh
    printf 'opencode server listening on #{base_url}\n'
    while true; do
      sleep 1
    done
    """)

    File.chmod!(launcher, 0o755)
    launcher
  end
end
