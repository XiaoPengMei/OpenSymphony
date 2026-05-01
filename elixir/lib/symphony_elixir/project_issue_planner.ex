defmodule SymphonyElixir.ProjectIssuePlanner do
  @moduledoc """
  Produces a project-scoped dispatch plan for multiple candidate issues.

  The planner is advisory only: it may order or defer issues, but the
  orchestrator remains responsible for revalidation, claiming, capacity checks,
  and spawning issue workers.
  """

  alias SymphonyElixir.{AppServer, Config}
  alias SymphonyElixir.Linear.Issue

  @callback plan_project_issues(String.t(), [Issue.t()], keyword()) ::
              {:ok, [[String.t()]]} | {:error, term()}

  @schema_version 1
  @planner_turn_timeout_ms 10_000

  @spec plan_project_issues(String.t(), [Issue.t()], keyword()) ::
          {:ok, [[String.t()]]} | {:error, term()}
  def plan_project_issues(project_key, issues, _opts \\ [])
      when is_binary(project_key) and is_list(issues) do
    with {:ok, workspace} <- create_planner_workspace(project_key),
         prompt <- build_prompt(project_key, issues),
         planner_issue <- planner_issue(project_key, issues),
         {:ok, session} <- AppServer.start_session(workspace, backend: "opencode", issue: planner_issue) do
      try do
        with {:ok, turn} <- run_planner_turn(session, prompt, planner_issue),
             {:ok, payload} <- extract_plan_payload(turn),
             {:ok, issue_id_waves} <- validate_plan(project_key, issues, payload) do
          {:ok, enforce_surface_safe_waves(issues, issue_id_waves)}
        end
      after
        AppServer.stop_session(session, backend: "opencode")
      end
    end
  end

  @spec validate_plan(String.t(), [Issue.t()], map() | String.t()) ::
          {:ok, [[String.t()]]} | {:error, term()}
  def validate_plan(project_key, issues, payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> validate_plan(project_key, issues, decoded)
      {:error, reason} -> {:error, {:invalid_plan_json, reason}}
    end
  end

  def validate_plan(project_key, issues, %{} = payload) when is_binary(project_key) and is_list(issues) do
    known_ids = issue_ids(issues)

    with :ok <- validate_schema_version(payload),
         :ok <- validate_project_key(project_key, payload),
         {:ok, batches} <- fetch_batches(payload),
         {:ok, deferred_ids} <- fetch_optional_issue_ids(payload, "defer_issue_ids"),
         {:ok, issue_id_waves} <- issue_id_waves_from_batches(batches),
         planned_ids <- List.flatten(issue_id_waves),
         :ok <- validate_known_ids(planned_ids ++ deferred_ids, known_ids),
         :ok <- validate_no_duplicates(planned_ids ++ deferred_ids),
         :ok <- validate_complete_coverage(planned_ids ++ deferred_ids, known_ids) do
      {:ok, enforce_surface_safe_waves(issues, issue_id_waves)}
    end
  end

  def validate_plan(_project_key, _issues, payload), do: {:error, {:invalid_plan_payload, payload}}

  defp create_planner_workspace(project_key) do
    settings = Config.settings!()
    safe_project = safe_segment(project_key)
    unique = System.unique_integer([:positive])
    workspace = Path.join([settings.workspace.root, ".symphony-planner", safe_project, Integer.to_string(unique)])

    with :ok <- File.mkdir_p(workspace),
         {:ok, canonical_workspace} <- Config.validate_workspace_path(workspace) do
      {:ok, canonical_workspace}
    end
  end

  defp build_prompt(project_key, issues) do
    issue_bundle =
      issues
      |> Enum.map(&issue_payload/1)
      |> Jason.encode!(pretty: true)

    """
    You are OpenSymphony's project-scoped dispatch planner.

    Decide which issues in this single Linear project can safely run now and in what parallel wave order.
    You must not edit files, run shell commands, claim issues, update Linear, or start implementation work.

    Project key: #{project_key}

    Rules:
    - Return only data matching the provided JSON schema.
    - Use hard Linear blockers as dependencies.
    - Each batch is a wave. Issues in the same wave may run concurrently.
    - Later waves are serial and must wait until all earlier-wave issues finish.
    - Prefer safe parallelism only when issues do not conflict on the same implementation surface.
    - Put issues that touch the same surface, depend on each other, or could race on the same files in different waves.
    - Put issues that should not run now in defer_issue_ids.
    - Every input issue id must appear exactly once, either in a batch issue_ids list or defer_issue_ids.

    Candidate issues:
    #{issue_bundle}
    """
  end

  defp planner_issue(project_key, issues) do
    %Issue{
      id: "planner-#{project_key}",
      identifier: "planner-#{project_key}",
      title: "Plan dispatch for #{length(issues)} issues in #{project_key}",
      description: "OpenSymphony project-scoped planning run",
      state: "Planning",
      project_id: project_key,
      project_slug: project_key,
      labels: []
    }
  end

  defp planner_format_schema do
    %{
      "type" => "json_schema",
      "retryCount" => 2,
      "schema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["schema_version", "project_key", "batches", "defer_issue_ids"],
        "properties" => %{
          "schema_version" => %{"type" => "integer", "const" => @schema_version},
          "project_key" => %{"type" => "string"},
          "batches" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["parallel_group", "issue_ids", "reason"],
              "properties" => %{
                "parallel_group" => %{"type" => "integer", "minimum" => 1},
                "issue_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
                "reason" => %{"type" => "string"}
              }
            }
          },
          "defer_issue_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
          "reason" => %{"type" => "string"}
        }
      }
    }
  end

  defp run_planner_turn(session, prompt, planner_issue) do
    task =
      Task.async(fn ->
        AppServer.run_turn(session, prompt, planner_issue,
          backend: "opencode",
          format: planner_format_schema()
        )
      end)

    case Task.yield(task, @planner_turn_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :planner_timeout}
    end
  end

  defp extract_plan_payload(%{result: result}), do: extract_plan_payload(result)
  defp extract_plan_payload(%{"result" => result}), do: extract_plan_payload(result)

  defp extract_plan_payload(%{"info" => %{"structured_output" => output}}) when is_map(output) or is_binary(output), do: {:ok, output}
  defp extract_plan_payload(%{info: %{structured_output: output}}) when is_map(output) or is_binary(output), do: {:ok, output}
  defp extract_plan_payload(%{} = payload), do: {:error, {:missing_structured_output, Map.keys(payload)}}
  defp extract_plan_payload(payload), do: {:error, {:missing_structured_output, payload}}

  defp validate_schema_version(%{"schema_version" => @schema_version}), do: :ok
  defp validate_schema_version(%{"schema_version" => version}), do: {:error, {:unsupported_schema_version, version}}
  defp validate_schema_version(_payload), do: {:error, :missing_schema_version}

  defp validate_project_key(project_key, %{"project_key" => project_key}), do: :ok
  defp validate_project_key(project_key, %{"project_key" => other}), do: {:error, {:project_key_mismatch, project_key, other}}
  defp validate_project_key(_project_key, _payload), do: {:error, :missing_project_key}

  defp fetch_batches(%{"batches" => batches}) when is_list(batches), do: {:ok, batches}
  defp fetch_batches(_payload), do: {:error, :missing_batches}

  defp fetch_optional_issue_ids(%{} = payload, key) do
    value = Map.get(payload, key, [])

    cond do
      is_list(value) and Enum.all?(value, &is_binary/1) -> {:ok, value}
      true -> {:error, {:invalid_issue_ids, key, value}}
    end
  end

  defp issue_id_waves_from_batches(batches) when is_list(batches) do
    Enum.reduce_while(batches, {:ok, []}, fn batch, {:ok, acc} ->
      case batch do
        %{"issue_ids" => ids} when is_list(ids) ->
          cond do
            ids == [] ->
              {:halt, {:error, {:empty_batch_issue_ids, batch}}}

            Enum.all?(ids, &is_binary/1) ->
              {:cont, {:ok, acc ++ [ids]}}

            true ->
              {:halt, {:error, {:invalid_batch_issue_ids, ids}}}
          end

        _ ->
          {:halt, {:error, {:invalid_batch, batch}}}
      end
    end)
  end

  defp validate_known_ids(ids, known_ids) do
    unknown_ids = Enum.reject(ids, &MapSet.member?(known_ids, &1))

    case unknown_ids do
      [] -> :ok
      _ -> {:error, {:unknown_issue_ids, unknown_ids}}
    end
  end

  defp validate_no_duplicates(ids) do
    duplicate_ids = ids -- Enum.uniq(ids)

    case duplicate_ids do
      [] -> :ok
      _ -> {:error, {:duplicate_issue_ids, Enum.uniq(duplicate_ids)}}
    end
  end

  defp validate_complete_coverage(ids, known_ids) do
    planned_ids = MapSet.new(ids)
    missing_ids = known_ids |> MapSet.difference(planned_ids) |> MapSet.to_list()

    case missing_ids do
      [] -> :ok
      _ -> {:error, {:missing_issue_ids, missing_ids}}
    end
  end

  defp issue_payload(%Issue{} = issue) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      priority: issue.priority,
      state: issue.state,
      labels: issue.labels,
      blocked_by: issue.blocked_by,
      created_at: maybe_datetime(issue.created_at),
      updated_at: maybe_datetime(issue.updated_at)
    }
  end

  defp enforce_surface_safe_waves(issues, issue_id_waves) when is_list(issues) and is_list(issue_id_waves) do
    issue_by_id = Map.new(issues, &{&1.id, &1})

    Enum.flat_map(issue_id_waves, fn issue_ids ->
      split_wave_by_surface(issue_ids, issue_by_id)
    end)
  end

  defp split_wave_by_surface(issue_ids, issue_by_id) do
    {waves, current_wave, _current_surfaces} =
      Enum.reduce(issue_ids, {[], [], MapSet.new()}, fn issue_id, {waves, current_wave, current_surfaces} ->
        surfaces = issue_by_id |> Map.get(issue_id) |> issue_surfaces()

        if surfaces_overlap?(surfaces, current_surfaces) do
          {waves ++ [current_wave], [issue_id], surfaces}
        else
          {waves, current_wave ++ [issue_id], MapSet.union(current_surfaces, surfaces)}
        end
      end)

    waves ++ [current_wave]
  end

  defp issue_surfaces(%Issue{} = issue) do
    text =
      [issue.title, issue.description | issue.labels || []]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    surface_keywords = [
      {:web, ["web", "网页", "页面", "react", "vite", "pwa", "h5"]},
      {:api, ["api", "backend", "后端", "fastify", "prisma", "database", "数据库"]},
      {:backoffice, ["backoffice", "后台", "admin", "管理台"]},
      {:replenishment_pc, ["replenishment", "pc", "补货", "桌面"]}
    ]

    surfaces =
      surface_keywords
      |> Enum.reduce(MapSet.new(), fn {surface, keywords}, surfaces ->
        if Enum.any?(keywords, &String.contains?(text, &1)) do
          MapSet.put(surfaces, surface)
        else
          surfaces
        end
      end)

    android_keywords = ["android", "安卓", "kotlin", "compose", "gradle", "room", "webview"]
    strong_android_keywords = ["kotlin", "compose", "gradle", "room", "webview"]

    if Enum.any?(strong_android_keywords, &String.contains?(text, &1)) or
         (not MapSet.member?(surfaces, :web) and Enum.any?(android_keywords, &String.contains?(text, &1))) do
      MapSet.put(surfaces, :android)
    else
      surfaces
    end
  end

  defp issue_surfaces(_issue), do: MapSet.new()

  defp surfaces_overlap?(surfaces, current_surfaces) do
    MapSet.size(surfaces) > 0 and not MapSet.disjoint?(surfaces, current_surfaces)
  end

  defp issue_ids(issues) do
    issues
    |> Enum.flat_map(fn
      %Issue{id: id} when is_binary(id) and id != "" -> [id]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp maybe_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp maybe_datetime(_datetime), do: nil

  defp safe_segment(value) when is_binary(value), do: String.replace(value, ~r/[^a-zA-Z0-9._-]/, "_")
end
