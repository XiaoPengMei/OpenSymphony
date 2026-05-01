defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, IssueConfig, Workflow}

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    prompt_template = resolve_prompt_template(issue, opts)
    _validated_template = parse_template!(prompt_template)

    render_prompt_template!(prompt_template, %{
      "attempt" => Keyword.get(opts, :attempt),
      "issue" => issue |> Map.from_struct() |> to_solid_map()
    })
  end

  defp render_prompt_template!(prompt_template, assigns) when is_binary(prompt_template) do
    prompt_template
    |> render_condition_blocks!(assigns)
    |> render_variable_tags!(assigns)
  end

  defp render_condition_blocks!(prompt_template, assigns) when is_binary(prompt_template) do
    prompt_template =
      Regex.replace(
        ~r/\{%\s*if\s+([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)\s*%\}(.*?)\{%\s*else\s*%\}(.*?)\{%\s*endif\s*%\}/s,
        prompt_template,
        fn _match, path, truthy_body, falsey_body ->
          value = fetch_assign_path!(assigns, String.split(path, "."), path)

          if truthy?(value) do
            truthy_body
          else
            falsey_body
          end
        end
      )

    Regex.replace(~r/\{%\s*if\s+([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)\s*%\}(.*?)\{%\s*endif\s*%\}/s, prompt_template, fn _match, path, body ->
      value = fetch_assign_path!(assigns, String.split(path, "."), path)

      if truthy?(value) do
        body
      else
        ""
      end
    end)
  end

  defp render_variable_tags!(prompt_template, assigns) when is_binary(prompt_template) do
    Regex.replace(~r/\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)\s*\}\}/, prompt_template, fn _match, path ->
      assigns
      |> fetch_assign_path!(String.split(path, "."), path)
      |> to_prompt_text()
    end)
  end

  defp fetch_assign_path!(value, [], _path), do: value

  defp fetch_assign_path!(%{} = value, [segment | rest], path) do
    case Map.fetch(value, segment) do
      {:ok, child} -> fetch_assign_path!(child, rest, path)
      :error -> raise_undefined_variable!(path)
    end
  end

  defp fetch_assign_path!(_value, _segments, path), do: raise_undefined_variable!(path)

  defp raise_undefined_variable!(path) do
    raise Solid.RenderError,
      errors: [
        %Solid.UndefinedVariableError{
          variable: path,
          original_name: path,
          loc: %{line: 1}
        }
      ],
      result: []
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_value), do: true

  defp to_prompt_text(nil), do: ""
  defp to_prompt_text(value) when is_binary(value), do: value
  defp to_prompt_text(value) when is_integer(value), do: Integer.to_string(value)
  defp to_prompt_text(value) when is_float(value), do: Float.to_string(value)
  defp to_prompt_text(value) when is_boolean(value), do: to_string(value)
  defp to_prompt_text(value) when is_list(value), do: Enum.map_join(value, "", &to_prompt_text/1)
  defp to_prompt_text(value), do: to_string(value)

  defp resolve_prompt_template(issue, opts) do
    case Keyword.get(opts, :issue_config) do
      %IssueConfig{prompt_template: prompt_template} ->
        default_prompt(prompt_template)

      _ ->
        if Config.global_mode?() do
          case IssueConfig.resolve(issue) do
            {:ok, %IssueConfig{prompt_template: prompt_template}} -> default_prompt(prompt_template)
            {:error, reason} -> raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
          end
        else
          Workflow.current()
          |> prompt_template!()
        end
    end
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.default_prompt_template()
    else
      prompt
    end
  end
end
