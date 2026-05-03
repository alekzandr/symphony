defmodule SymphonyElixir.Codex.LocalResearch do
  @moduledoc """
  Searches workspace files and asks a local Ollama model to summarize the relevant snippets.
  """

  alias SymphonyElixir.{Config, PathSafety, SSH}

  @default_model "gemma4:e2b"
  @default_base_url "http://127.0.0.1:11434"
  @default_timeout_ms 15_000
  @default_max_files 5
  @default_context_lines 24
  @default_search_terms 6
  @rg_globs [
    "!**/.git/**",
    "!**/deps/**",
    "!**/_build/**",
    "!**/log/**",
    "!**/node_modules/**"
  ]
  @stopwords MapSet.new([
               "a",
               "an",
               "and",
               "as",
               "at",
               "be",
               "by",
               "do",
               "for",
               "from",
               "if",
               "in",
               "into",
               "is",
               "it",
               "local",
               "of",
               "on",
               "or",
               "read",
               "search",
               "the",
               "this",
               "that",
               "to",
               "use",
               "using",
               "with",
               "file",
               "files",
               "agent",
               "model"
             ])

  @spec search(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def search(query_or_args, opts \\ []) do
    with {:ok, query, requested_path_hints, max_files, context_lines} <-
           normalize_arguments(query_or_args, opts),
         {:ok, workspace, worker_host} <- workspace_context(opts),
         {:ok, requested_paths} <- normalize_requested_paths(requested_path_hints, workspace) do
      search_terms = search_terms(query)
      search_result = search_workspace(workspace, worker_host, search_terms, opts)
      {search_hits, search_error} = search_result
      timeout_ms = local_search_timeout(opts)

      docs =
        build_documents(
          workspace,
          worker_host,
          requested_paths,
          search_hits,
          search_error,
          max_files,
          context_lines,
          timeout_ms
        )

      {:ok, build_payload(query, workspace, worker_host, requested_paths, search_terms, docs, opts)}
    end
  end

  defp normalize_arguments(query_or_args, opts) when is_binary(query_or_args) do
    query = String.trim(query_or_args)

    if query == "" do
      {:error, :missing_query}
    else
      {:ok, query, requested_path_hints(opts), max_files(opts), context_lines(opts)}
    end
  end

  defp normalize_arguments(query_or_args, opts) when is_map(query_or_args) do
    query = argument_value(query_or_args, "query") || argument_value(query_or_args, :query)

    path_hints =
      argument_value(query_or_args, "paths") ||
        argument_value(query_or_args, :paths) ||
        requested_path_hints(opts)

    max_files =
      argument_value(query_or_args, "maxFiles") ||
        argument_value(query_or_args, :maxFiles) ||
        max_files(opts)

    context_lines =
      argument_value(query_or_args, "contextLines") || argument_value(query_or_args, :contextLines) || context_lines(opts)

    with {:ok, query} <- normalize_query(query),
         {:ok, path_hints} <- normalize_path_hints(path_hints),
         {:ok, max_files} <- normalize_positive_integer(max_files, @default_max_files),
         {:ok, context_lines} <- normalize_positive_integer(context_lines, @default_context_lines) do
      {:ok, query, path_hints, max_files, context_lines}
    end
  end

  defp normalize_arguments(_, _opts), do: {:error, :invalid_arguments}

  defp normalize_query(nil), do: {:error, :missing_query}

  defp normalize_query(query) when is_binary(query) do
    trimmed = String.trim(query)

    if trimmed == "" do
      {:error, :missing_query}
    else
      {:ok, trimmed}
    end
  end

  defp normalize_query(_query), do: {:error, :invalid_arguments}

  defp normalize_path_hints(path_hints) when is_list(path_hints) do
    path_hints
    |> Enum.reduce_while({:ok, []}, fn path_hint, {:ok, acc} ->
      case normalize_path_hint(path_hint) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, path_hints} -> {:ok, Enum.reverse(path_hints)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_path_hints(_path_hints), do: {:error, :invalid_paths}

  defp normalize_path_hint(path_hint) when is_binary(path_hint) do
    trimmed = String.trim(path_hint)

    if trimmed == "" do
      {:error, :invalid_paths}
    else
      {:ok, trimmed}
    end
  end

  defp normalize_path_hint(_path_hint), do: {:error, :invalid_paths}

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: {:ok, value}
  defp normalize_positive_integer(_value, default), do: {:ok, default}

  defp requested_path_hints(opts) do
    opts
    |> Keyword.get(:paths, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp max_files(opts), do: config_integer(opts, :max_files, @default_max_files)
  defp context_lines(opts), do: config_integer(opts, :context_lines, @default_context_lines)

  defp config_integer(config, key, default) do
    case config_lookup(config, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp workspace_context(opts) do
    with {:ok, workspace} <- workspace_root(Keyword.get(opts, :workspace), Keyword.get(opts, :worker_host)) do
      {:ok, workspace, Keyword.get(opts, :worker_host)}
    end
  end

  defp workspace_root(nil, _worker_host), do: {:error, :missing_workspace}

  defp workspace_root(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)

    case PathSafety.canonicalize(expanded_workspace) do
      {:ok, canonical_workspace} -> {:ok, canonical_workspace}
      {:error, {:path_canonicalize_failed, path, reason}} -> {:error, {:workspace_unreadable, path, reason}}
    end
  end

  defp workspace_root(workspace, _worker_host) when is_binary(workspace) do
    trimmed = String.trim(workspace)

    if trimmed == "" do
      {:error, :missing_workspace}
    else
      {:ok, Path.expand(trimmed)}
    end
  end

  defp workspace_root(_workspace, _worker_host), do: {:error, :missing_workspace}

  defp normalize_requested_paths(path_hints, workspace) do
    workspace_prefix = workspace_prefix(workspace)

    path_hints
    |> Enum.reduce_while({:ok, []}, fn path_hint, {:ok, acc} ->
      case normalize_requested_path(path_hint, workspace, workspace_prefix) do
        {:ok, normalized_path} -> {:cont, {:ok, [normalized_path | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_requested_path(path_hint, workspace, workspace_prefix) do
    expanded_path = Path.expand(path_hint, workspace)

    cond do
      expanded_path == workspace -> {:error, {:invalid_workspace_path, path_hint}}
      String.starts_with?(expanded_path <> "/", workspace_prefix) -> {:ok, expanded_path}
      true -> {:error, {:invalid_workspace_path, path_hint}}
    end
  end

  defp workspace_prefix(workspace), do: String.trim_trailing(workspace, "/") <> "/"

  defp search_terms(query) do
    [query | query_tokens(query)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@default_search_terms)
  end

  defp query_tokens(query) when is_binary(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]_.\/:-]+/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn token ->
      token == "" or String.length(token) < 3 or MapSet.member?(@stopwords, token)
    end)
  end

  defp search_workspace(workspace, worker_host, search_terms, opts) do
    timeout_ms = local_search_timeout(opts)

    command =
      [
        "rg -n -i -F --hidden",
        Enum.map_join(@rg_globs, " ", fn glob -> "--glob " <> shell_escape(glob) end),
        Enum.map_join(search_terms, " ", fn term -> "-e " <> shell_escape(term) end),
        "-- ."
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    case run_workspace_command(workspace, worker_host, command, timeout_ms) do
      {:ok, {output, 0}} ->
        {grouped_hits(output), nil}

      {:ok, {_output, 1}} ->
        {[], nil}

      {:ok, {output, status}} ->
        {[], {:search_command_failed, status, trim_output(output)}}

      {:error, reason} ->
        {[], {:search_command_failed, reason}}
    end
  end

  defp grouped_hits(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, &accumulate_hit/2)
    |> Enum.map(fn {path, hits} ->
      %{path: path, hits: Enum.reverse(hits)}
    end)
    |> Enum.sort_by(fn %{path: path, hits: hits} -> {-length(hits), path} end)
  end

  defp accumulate_hit(line, acc) do
    case String.split(line, ":", parts: 3) do
      [path, line_number, content] -> accumulate_parsed_hit(acc, path, line_number, content)
      _ -> acc
    end
  end

  defp accumulate_parsed_hit(acc, path, line_number, content) do
    case Integer.parse(line_number) do
      {line, ""} ->
        hit = %{line: line, text: content}
        Map.update(acc, path, [hit], &[hit | &1])

      _ ->
        acc
    end
  end

  defp build_documents(
         workspace,
         worker_host,
         requested_paths,
         search_hits,
         search_error,
         max_files,
         context_lines,
         timeout_ms
       ) do
    search_docs = docs_from_search_hits(search_hits, workspace, worker_host, context_lines, max_files, timeout_ms)
    requested_docs =
      docs_from_requested_paths(requested_paths, workspace, worker_host, context_lines, max_files, timeout_ms)

    documents =
      (requested_docs ++ search_docs)
      |> Enum.uniq_by(& &1.path)
      |> Enum.take(max_files)

    missing_paths =
      requested_paths
      |> Enum.reject(fn path -> Enum.any?(documents, &(&1.path == display_path(path, workspace))) end)
      |> Enum.map(&display_path(&1, workspace))

    %{documents: documents, missing_paths: missing_paths, search_error: search_error}
  end

  defp docs_from_requested_paths(
         requested_paths,
         workspace,
         worker_host,
         context_lines,
         max_files,
         timeout_ms
       ) do
    requested_paths
    |> Enum.take(max_files)
    |> Enum.reduce([], fn path, acc ->
      case read_excerpt(workspace, worker_host, path, 1, context_lines, timeout_ms) do
        {:ok, excerpt} ->
          [%{kind: "requested", path: display_path(path, workspace), line: 1, hit_count: 0, excerpt: excerpt} | acc]

        {:error, _reason} ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp docs_from_search_hits(
         search_hits,
         workspace,
         worker_host,
         context_lines,
         max_files,
         timeout_ms
       ) do
    search_hits
    |> Enum.take(max_files)
    |> Enum.reduce([], fn %{path: path, hits: hits}, acc ->
      first_hit = hd(hits)
      abs_path = Path.expand(path, workspace)

      case read_excerpt(workspace, worker_host, abs_path, first_hit.line, context_lines, timeout_ms) do
        {:ok, excerpt} ->
          [
            %{
              kind: "search",
              path: display_path(abs_path, workspace),
              line: first_hit.line,
              hit_count: length(hits),
              excerpt: excerpt
            }
            | acc
          ]

        {:error, _reason} ->
          [
            %{
              kind: "search",
              path: display_path(abs_path, workspace),
              line: first_hit.line,
              hit_count: length(hits),
              excerpt: excerpt_fallback(first_hit.text)
            }
            | acc
          ]
      end
    end)
    |> Enum.reverse()
  end

  defp read_excerpt(workspace, worker_host, path, line_number, context_lines, timeout_ms) do
    start_line = max(line_number - context_lines, 1)
    end_line = max(line_number + context_lines, start_line)
    range = "#{start_line},#{end_line}p"
    command = "sed -n #{shell_escape(range)} #{shell_escape(relative_path(path, workspace))}"

    case run_workspace_command(workspace, worker_host, command, timeout_ms) do
      {:ok, {output, 0}} -> {:ok, format_excerpt(output, start_line)}
      {:ok, {output, status}} when status != 0 -> {:error, {:excerpt_command_failed, status, trim_output(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_excerpt(output, start_line) do
    text = IO.iodata_to_binary(output)

    if String.trim(text) == "" do
      "(file is empty)"
    else
      text
      |> String.trim_trailing("\n")
      |> String.split("\n", trim: false)
      |> Enum.with_index(start_line)
      |> Enum.map_join("\n", fn {line, line_number} ->
        "#{line_number}: #{line}"
      end)
    end
  end

  defp excerpt_fallback(text) when is_binary(text) do
    text
    |> String.trim()
    |> case do
      "" -> "(matched line was empty)"
      trimmed -> trimmed
    end
  end

  defp summarize(query, docs, opts) do
    if docs == [] do
      {:ok, fallback_summary(query, docs), %{status: "no_results"}}
    else
      summarize_with_docs(query, docs, opts)
    end
  end

  defp summarize_with_docs(query, docs, opts) do
    base_url = local_search_base_url(opts)
    model = local_search_model(opts)
    timeout_ms = local_search_timeout(opts)
    client = Keyword.get(opts, :ollama_client, &default_ollama_client/3)
    prompt = build_summary_prompt(query, docs)

    request = %{
      "model" => model,
      "stream" => false,
      "messages" => [
        %{
          "role" => "system",
          "content" => """
          You are a local repository research assistant. Answer the user's question using only the provided file excerpts.
          Keep the answer concise and actionable.
          """
        },
        %{"role" => "user", "content" => prompt}
      ]
    }

    case client.(chat_url(base_url), request, timeout_ms) do
      {:ok, response} -> summarize_ollama_response(query, docs, response)
      {:error, reason} -> fallback_summary_response(query, docs, reason)
    end
  end

  defp summarize_ollama_response(query, docs, response) do
    case extract_ollama_content(response) do
      {:ok, content} -> {:ok, String.trim(content), %{status: "ok"}}
      {:error, reason} -> fallback_summary_response(query, docs, reason)
    end
  end

  defp fallback_summary_response(query, docs, reason) do
    {:ok, fallback_summary(query, docs), %{status: "fallback", reason: inspect(reason)}}
  end

  defp build_summary_prompt(query, docs) do
    excerpts =
      Enum.map_join(docs, "\n", fn doc ->
        """
        - path: #{doc.path}
          kind: #{doc.kind}
          line: #{doc.line}
          hit_count: #{doc.hit_count}
          excerpt:
        #{indent_block(doc.excerpt, 12)}
        """
      end)

    """
    Question:
    #{query}

    File excerpts:
    #{excerpts}
    """
  end

  defp indent_block(block, spaces) when is_binary(block) do
    indent = String.duplicate(" ", spaces)

    block
    |> String.trim_trailing()
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &"#{indent}#{&1}")
  end

  defp fallback_summary(query, []), do: "No matching files were found for `#{query}`."

  defp fallback_summary(query, docs) do
    preview =
      Enum.map_join(Enum.take(docs, 3), "\n", fn doc ->
        "- #{doc.path}: #{String.slice(doc.excerpt, 0, 240)}"
      end)

    """
    Local Ollama summary unavailable. Review the file excerpts below for `#{query}`:

    #{preview}
    """
    |> String.trim()
  end

  defp build_payload(query, workspace, worker_host, requested_paths, search_terms, docs_bundle, opts) do
    docs = docs_bundle.documents
    {:ok, summary, ollama_meta} = summarize(query, docs, opts)
    ollama_payload = stringify_map_keys(ollama_meta)

    %{
      "query" => query,
      "workspace" => display_path(workspace, workspace),
      "workerHost" => worker_host,
      "model" => local_search_model(opts),
      "baseUrl" => local_search_base_url(opts),
      "status" => payload_status(docs, ollama_meta, docs_bundle.search_error),
      "searchTerms" => search_terms,
      "requestedPaths" => Enum.map(requested_paths, &display_path(&1, workspace)),
      "missingPaths" => docs_bundle.missing_paths,
      "searchError" => format_error(docs_bundle.search_error),
      "ollama" => ollama_payload,
      "sources" => Enum.map(docs, &source_payload/1),
      "summary" => summary
    }
  end

  defp payload_status([], _ollama_meta, nil), do: "no_results"
  defp payload_status([], _ollama_meta, _search_error), do: "fallback"
  defp payload_status(_docs, %{status: "ok"}, _search_error), do: "ok"
  defp payload_status(_docs, _ollama_meta, _search_error), do: "fallback"

  defp source_payload(doc) do
    %{
      "path" => doc.path,
      "kind" => doc.kind,
      "line" => doc.line,
      "hitCount" => doc.hit_count,
      "excerpt" => doc.excerpt
    }
  end

  defp format_error(nil), do: nil
  defp format_error(reason), do: inspect(reason)

  defp stringify_map_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), stringify_map_keys(nested_value)}
    end)
  end

  defp stringify_map_keys(value), do: value

  defp local_search_model(opts) do
    config = local_search_config(opts)
    config_string(config, "model", @default_model)
  end

  defp local_search_base_url(opts) do
    config = local_search_config(opts)
    config_string(config, "base_url", @default_base_url)
  end

  defp local_search_timeout(opts) do
    config = local_search_config(opts)
    config_integer(config, "timeout_ms", @default_timeout_ms)
  end

  defp local_search_config(opts) do
    config_lookup(opts, :local_search_config) ||
      Map.get(Config.settings!().codex.config, "local_search", %{})
  end

  defp config_string(config, key, default) when is_map(config) do
    case config_lookup(config, key) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          default
        else
          value
        end

      _ ->
        default
    end
  end

  defp config_lookup(config, key) when is_list(config) and is_atom(key) do
    Keyword.get(config, key)
  end

  defp config_lookup(config, key) when is_map(config) and is_binary(key) do
    Map.get(config, key) || Map.get(config, String.to_atom(key))
  end

  defp chat_url(base_url) do
    String.trim_trailing(base_url, "/") <> "/api/chat"
  end

  defp extract_ollama_content(%Req.Response{status: status, body: body}) when status in 200..299 do
    extract_content(body)
  end

  defp extract_ollama_content(%Req.Response{status: status, body: body}) do
    {:error, {:ollama_http_status, status, summarize_body(body)}}
  end

  defp extract_ollama_content(%{"message" => %{"content" => content}}) when is_binary(content), do: {:ok, content}
  defp extract_ollama_content(%{message: %{content: content}}) when is_binary(content), do: {:ok, content}

  defp extract_ollama_content(%{"choices" => [%{"message" => %{"content" => content}} | _]}) when is_binary(content),
    do: {:ok, content}

  defp extract_ollama_content(%{choices: [%{message: %{content: content}} | _]}) when is_binary(content),
    do: {:ok, content}

  defp extract_ollama_content(other), do: {:error, {:ollama_unexpected_body, summarize_body(other)}}

  defp extract_content(body) when is_map(body), do: extract_ollama_content(body)
  defp extract_content(body) when is_binary(body), do: Jason.decode(body) |> normalize_decoded_body()
  defp extract_content(other), do: {:error, {:ollama_unexpected_body, inspect(other)}}

  defp normalize_decoded_body({:ok, decoded}), do: extract_ollama_content(decoded)
  defp normalize_decoded_body({:error, reason}), do: {:error, {:ollama_invalid_json, reason}}

  defp summarize_body(body) when is_binary(body), do: trim_output(body)
  defp summarize_body(body), do: inspect(body, limit: 10, printable_limit: 1_000)

  defp trim_output(output) when is_binary(output) do
    output
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> ""
      text -> String.slice(text, 0, 240)
    end
  end

  defp default_ollama_client(url, request, timeout_ms) do
    Req.post(url,
      json: request,
      connect_options: [timeout: timeout_ms],
      receive_timeout: timeout_ms
    )
  end

  defp run_workspace_command(workspace, nil, command, timeout_ms) when is_binary(workspace) and is_binary(command) do
    run_with_timeout(timeout_ms, fn ->
      {:ok, System.cmd("bash", ["-lc", command], cd: workspace, stderr_to_stdout: true)}
    end)
  end

  defp run_workspace_command(workspace, worker_host, command, timeout_ms)
       when is_binary(workspace) and is_binary(worker_host) and is_binary(command) do
    remote_command = "cd #{shell_escape(workspace)} && #{command}"

    run_with_timeout(timeout_ms, fn ->
      SSH.run(worker_host, remote_command, stderr_to_stdout: true)
    end)
  end

  defp run_with_timeout(timeout_ms, fun) when is_integer(timeout_ms) and timeout_ms > 0 and is_function(fun, 0) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_research_timeout, timeout_ms}}
    end
  end

  defp relative_path(path, workspace) do
    Path.relative_to(path, workspace)
  end

  defp display_path(path, workspace) do
    relative_path = relative_path(path, workspace)

    if relative_path == "." do
      path
    else
      relative_path
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp argument_value(arguments, key) when is_map(arguments) do
    Map.get(arguments, key) || Map.get(arguments, to_string(key))
  end
end
