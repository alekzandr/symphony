defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Codex.LocalResearch, Linear.Client}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @workspace_research_tool "workspace_research"
  @workspace_research_description """
  Search workspace files, read the relevant excerpts, and summarize them with a local Ollama model.
  """
  @workspace_research_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "Question or search request to run against the workspace."
      },
      "paths" => %{
        "type" => "array",
        "description" => "Optional workspace-relative or absolute file paths to prioritize.",
        "items" => %{"type" => "string"}
      },
      "maxFiles" => %{
        "type" => ["integer", "null"],
        "description" => "Optional maximum number of files to include."
      },
      "contextLines" => %{
        "type" => ["integer", "null"],
        "description" => "Optional context line count around matching excerpts."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @workspace_research_tool ->
        execute_workspace_research(arguments, opts)

      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @workspace_research_tool,
        "description" => @workspace_research_description,
        "inputSchema" => @workspace_research_input_schema
      },
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_workspace_research(arguments, opts) do
    case LocalResearch.search(arguments, opts) do
      {:ok, response} ->
        dynamic_tool_response(true, encode_payload(response))

      {:error, reason} ->
        failure_response(workspace_research_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp workspace_research_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`workspace_research` requires a non-empty `query` string."
      }
    }
  end

  defp workspace_research_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`workspace_research` expects either a search string or an object with `query`, optional `paths`, `maxFiles`, and `contextLines`."
      }
    }
  end

  defp workspace_research_error_payload(:invalid_paths) do
    %{
      "error" => %{
        "message" => "`workspace_research.paths` must be an array of workspace-relative path strings."
      }
    }
  end

  defp workspace_research_error_payload(:missing_workspace) do
    %{
      "error" => %{
        "message" => "`workspace_research` requires workspace context from the app-server session."
      }
    }
  end

  defp workspace_research_error_payload({:workspace_unreadable, path, reason}) do
    %{
      "error" => %{
        "message" => "Symphony could not read workspace `#{path}`.",
        "reason" => inspect(reason)
      }
    }
  end

  defp workspace_research_error_payload({:invalid_workspace_path, path}) do
    %{
      "error" => %{
        "message" => "`workspace_research.paths` entry `#{path}` must stay within the workspace."
      }
    }
  end

  defp workspace_research_error_payload({:search_command_failed, status, output}) do
    %{
      "error" => %{
        "message" => "`workspace_research` failed to search the workspace.",
        "status" => status,
        "output" => output
      }
    }
  end

  defp workspace_research_error_payload({:search_command_failed, reason}) do
    %{
      "error" => %{
        "message" => "`workspace_research` failed to search the workspace.",
        "reason" => inspect(reason)
      }
    }
  end

  defp workspace_research_error_payload(reason) do
    %{
      "error" => %{
        "message" => "`workspace_research` tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
