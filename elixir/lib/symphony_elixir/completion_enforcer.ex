defmodule SymphonyElixir.CompletionEnforcer do
  @moduledoc """
  Conservatively promotes completed issues to the configured review state.

  The first implementation intentionally accepts only an explicit marker file inside the issue
  workspace as completion evidence. A normal agent turn is not enough proof by itself.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Tracker

  @type result ::
          {:ok, :completed}
          | {:ok, :disabled}
          | {:ok, :missing_workspace}
          | {:ok, :missing_marker}
          | {:ok, :not_active}
          | {:error, term()}

  @spec enforce(Issue.t(), Path.t() | nil, Schema.t()) :: result()
  def enforce(%Issue{} = issue, workspace_path, %Schema{} = settings) do
    completion = settings.completion

    cond do
      !completion.enabled ->
        {:ok, :disabled}

      !is_binary(workspace_path) or String.trim(workspace_path) == "" ->
        {:ok, :missing_workspace}

      !active_issue_state?(issue.state, settings.tracker.active_states) ->
        {:ok, :not_active}

      !completion_marker_exists?(workspace_path, completion.marker_path) ->
        {:ok, :missing_marker}

      true ->
        complete_issue(issue, workspace_path, completion)
    end
  end

  defp complete_issue(%Issue{id: issue_id, identifier: identifier}, workspace_path, completion) do
    case Tracker.update_issue_state(issue_id, completion.target_state) do
      :ok ->
        Logger.info("Completion marker found for issue_id=#{issue_id} issue_identifier=#{identifier}; moved to #{completion.target_state}")
        maybe_create_comment(issue_id, identifier, workspace_path, completion)
        {:ok, :completed}

      {:error, reason} ->
        Logger.warning("Failed to move completed issue_id=#{issue_id} issue_identifier=#{identifier} to #{completion.target_state}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_create_comment(issue_id, identifier, workspace_path, %{comment_enabled: true, target_state: target_state}) do
    body = "OpenSymphony found the workspace completion marker and moved this issue to `#{target_state}`.\n\nIssue: `#{identifier}`\nWorkspace: `#{workspace_path}`"

    case Tracker.create_comment(issue_id, body) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to create completion audit comment for issue_id=#{issue_id}: #{inspect(reason)}")
    end
  end

  defp maybe_create_comment(_issue_id, _identifier, _workspace_path, _completion), do: :ok

  defp completion_marker_exists?(workspace_path, marker_path) do
    with {:ok, marker_abs_path} <- workspace_marker_path(workspace_path, marker_path),
         true <- File.regular?(marker_abs_path),
         {:ok, marker_real_path} <- PathSafety.canonicalize(marker_abs_path),
         {:ok, workspace_real_path} <- PathSafety.canonicalize(workspace_path) do
      inside_workspace?(marker_real_path, workspace_real_path)
    else
      _ -> false
    end
  end

  defp workspace_marker_path(workspace_path, marker_path) do
    workspace_abs_path = Path.expand(workspace_path)
    marker_abs_path = Path.expand(marker_path, workspace_abs_path)

    if inside_workspace?(marker_abs_path, workspace_abs_path) do
      {:ok, marker_abs_path}
    else
      :error
    end
  end

  defp inside_workspace?(path, workspace_path) do
    path == workspace_path or String.starts_with?(path, workspace_path <> "/")
  end

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) and is_list(active_states) do
    normalized_state = normalize_state(state_name)
    Enum.any?(active_states, &(normalize_state(&1) == normalized_state))
  end

  defp active_issue_state?(_state_name, _active_states), do: false

  defp normalize_state(state_name) when is_binary(state_name), do: state_name |> String.trim() |> String.downcase()
  defp normalize_state(state_name), do: state_name |> to_string() |> normalize_state()
end
