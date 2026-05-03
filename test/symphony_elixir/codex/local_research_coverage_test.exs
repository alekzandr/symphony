defmodule SymphonyElixir.Codex.LocalResearchCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.LocalResearch

  test "search/2 honors keyword options and falls back to defaults for blank local search config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-research-coverage-config-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "README.md"), "requested path alpha\n")
      File.write!(Path.join(workspace, "lib/example.ex"), "defmodule Example do\n  # needle\nend\n")

      test_pid = self()

      assert {:ok, payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 paths: ["README.md"],
                 max_files: 2,
                 context_lines: 1,
                 local_search_config: %{
                   model: " ",
                   base_url: "",
                   timeout_ms: 0
                 },
                 ollama_client: fn url, request, timeout_ms ->
                   send(test_pid, {:ollama_client_called, url, request, timeout_ms})
                   {:ok, %{"choices" => [%{"message" => %{"content" => "choice summary"}}]}}
                 end
               )

      assert_received {:ollama_client_called, "http://127.0.0.1:11434/api/chat", request, 15_000}
      assert request["model"] == "gemma4:e2b"
      assert request["stream"] == false

      assert payload["workspace"] == workspace
      assert payload["model"] == "gemma4:e2b"
      assert payload["baseUrl"] == "http://127.0.0.1:11434"
      assert payload["requestedPaths"] == ["README.md"]
      assert payload["status"] == "ok"
      assert payload["summary"] == "choice summary"
      assert Enum.map(payload["sources"], & &1["kind"]) == ["requested", "search"]
      assert Enum.map(payload["sources"], & &1["path"]) == ["README.md", "lib/example.ex"]

      assert {:ok, default_payload} =
               LocalResearch.search(
                 %{"query" => "needle", "paths" => ["README.md"], "maxFiles" => 0, "contextLines" => 0},
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:ok, %{message: %{content: "atom summary"}}}
                 end
               )

      assert default_payload["requestedPaths"] == ["README.md"]
      assert default_payload["model"] == "gemma4:e2b"
      assert default_payload["baseUrl"] == "http://127.0.0.1:11434"
      assert default_payload["status"] == "ok"
      assert default_payload["summary"] == "atom summary"
    after
      File.rm_rf(test_root)
    end
  end

  test "search/2 returns explicit errors for malformed arguments and workspace roots" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-research-coverage-errors-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      long_workspace = Path.join(test_root, String.duplicate("a", 5_000))

      assert {:error, :invalid_arguments} = LocalResearch.search(:bad, workspace: workspace)
      assert {:error, :missing_query} = LocalResearch.search(%{}, workspace: workspace)
      assert {:error, :invalid_arguments} = LocalResearch.search(%{"query" => 123}, workspace: workspace)
      assert {:error, :invalid_paths} = LocalResearch.search(%{"query" => "needle", "paths" => "oops"}, workspace: workspace)
      assert {:error, :invalid_paths} = LocalResearch.search(%{"query" => "needle", "paths" => [123]}, workspace: workspace)
      assert {:error, :invalid_paths} = LocalResearch.search(%{"query" => "needle", "paths" => [" "]}, workspace: workspace)
      assert {:error, {:invalid_workspace_path, "../outside"}} =
               LocalResearch.search(%{"query" => "needle", "paths" => ["../outside"]}, workspace: workspace)

      assert {:error, {:invalid_workspace_path, ^workspace}} =
               LocalResearch.search(%{"query" => "needle", "paths" => [workspace]}, workspace: workspace)

      assert {:error, :missing_workspace} = LocalResearch.search("needle")
      assert {:error, :missing_workspace} = LocalResearch.search("needle", workspace: 123)
      assert {:error, :missing_workspace} = LocalResearch.search("needle", workspace: " ", worker_host: "worker-a")

      assert {:error, {:workspace_unreadable, ^long_workspace, _reason}} =
               LocalResearch.search("needle", workspace: long_workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "search/2 reports search command failures when rg exits non-zero" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-research-coverage-rg-failure-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      workspace = Path.join(test_root, "workspace")
      fake_bin_dir = install_fake_commands!(test_root, rg_failure_script(), sed_noop_script())
      File.mkdir_p!(workspace)
      System.put_env("PATH", fake_bin_dir <> ":" <> (previous_path || ""))

      assert {:ok, payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   flunk("ollama client should not be called when no workspace matches are found")
                 end
               )

      assert payload["status"] == "fallback"
      assert payload["sources"] == []
      assert payload["summary"] == "No matching files were found for `needle`."
      assert payload["searchError"] == "{:search_command_failed, 2, \"\"}"
    after
      File.rm_rf(test_root)
    end
  end

  test "search/2 falls back to excerpt text when reads fail and preserves missing paths" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-research-coverage-excerpt-fallback-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "README.md"), "requested alpha\n")
      File.write!(Path.join(workspace, "lib/example.ex"), "defmodule Example do\n  # needle\nend\n")

      fake_bin_dir = install_fake_commands!(test_root, rg_excerpt_script(), sed_excerpt_script())
      System.put_env("PATH", fake_bin_dir <> ":" <> (previous_path || ""))

      assert {:ok, payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 paths: ["README.md", "missing.txt"],
                 local_search_config: %{
                   model: "gpt-5.5",
                   base_url: "http://example.com",
                   timeout_ms: 25_000
                 },
                 ollama_client: fn _url, _request, timeout_ms ->
                   assert timeout_ms == 25_000
                   {:ok, %{choices: [%{message: %{content: "choice summary"}}]}}
                 end
               )

      assert payload["status"] == "ok"
      assert payload["requestedPaths"] == ["README.md", "missing.txt"]
      assert payload["missingPaths"] == ["missing.txt"]
      assert payload["summary"] == "choice summary"
      assert Enum.map(payload["sources"], & &1["kind"]) == ["requested", "search", "search"]
      assert Enum.map(payload["sources"], & &1["path"]) == ["README.md", "lib/example.ex", "lib/other.ex"]

      [requested_source, first_search_source, second_search_source] = payload["sources"]
      assert requested_source["excerpt"] == "1: requested alpha"
      assert first_search_source["excerpt"] == "(matched line was empty)"
      assert second_search_source["excerpt"] == "nonempty search line"
    after
      File.rm_rf(test_root)
    end
  end

  test "search/2 times out slow excerpt reads" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-research-coverage-timeout-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      fake_bin_dir = install_fake_commands!(test_root, rg_single_hit_script(), sed_timeout_script())
      System.put_env("PATH", fake_bin_dir <> ":" <> (previous_path || ""))

      assert {:ok, payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 local_search_config: %{timeout_ms: 100},
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:ok, %{"message" => %{"content" => "timeout summary"}}}
                 end
               )

      assert payload["status"] == "ok"
      assert payload["sources"] == [%{"excerpt" => "needle line", "hitCount" => 1, "kind" => "search", "line" => 3, "path" => "lib/example.ex"}]
      assert payload["summary"] == "timeout summary"
      assert payload["searchError"] == nil
    after
      File.rm_rf(test_root)
    end
  end

  test "search/2 reports search command timeouts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-research-coverage-search-timeout-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      fake_bin_dir = install_fake_commands!(test_root, rg_timeout_script(), sed_noop_script())
      System.put_env("PATH", fake_bin_dir <> ":" <> (previous_path || ""))

      assert {:ok, payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 local_search_config: %{timeout_ms: 50},
                 ollama_client: fn _url, _request, _timeout_ms ->
                   flunk("ollama client should not be called when the search command times out")
                 end
               )

      assert payload["status"] == "fallback"
      assert payload["sources"] == []
      assert payload["summary"] == "No matching files were found for `needle`."
      assert payload["searchError"] =~ "workspace_research_timeout"
    after
      File.rm_rf(test_root)
    end
  end

  test "search/2 normalizes alternate Ollama response bodies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-research-coverage-ollama-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "README.md"), "needle line\n")
      File.write!(Path.join(workspace, "lib/example.ex"), "defmodule Example do\n  # needle\nend\n")

      assert {:ok, atom_payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:ok, %{message: %{content: "atom summary"}}}
                 end
               )

      assert atom_payload["status"] == "ok"
      assert atom_payload["summary"] == "atom summary"

      assert {:ok, map_payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:ok, %Req.Response{status: 200, body: %{"message" => %{"content" => "map body summary"}}}}
                 end
               )

      assert map_payload["status"] == "ok"
      assert map_payload["summary"] == "map body summary"

      assert {:ok, json_payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:ok, %Req.Response{status: 200, body: ~s({"message":{"content":"json body summary"}})}}
                 end
               )

      assert json_payload["status"] == "ok"
      assert json_payload["summary"] == "json body summary"

      assert {:ok, choice_payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:ok, %{"choices" => [%{"message" => %{"content" => "choice summary"}}]}}
                 end
               )

      assert choice_payload["status"] == "ok"
      assert choice_payload["summary"] == "choice summary"

      assert {:ok, invalid_json_payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:ok, %Req.Response{status: 200, body: "not-json"}}
                 end
               )

      assert invalid_json_payload["status"] == "fallback"
      assert invalid_json_payload["ollama"]["reason"] =~ "ollama_invalid_json"

      assert {:ok, atom_body_payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:ok, %Req.Response{status: 200, body: :ok}}
                 end
               )

      assert atom_body_payload["status"] == "fallback"
      assert atom_body_payload["ollama"]["reason"] =~ "ollama_unexpected_body"

      assert {:ok, http_error_payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:ok, %Req.Response{status: 503, body: "service unavailable"}}
                 end
               )

      assert http_error_payload["status"] == "fallback"
      assert http_error_payload["ollama"]["reason"] =~ "ollama_http_status"

      assert {:ok, unexpected_payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:ok, %{foo: "bar"}}
                 end
               )

      assert unexpected_payload["status"] == "fallback"
      assert unexpected_payload["ollama"]["reason"] =~ "ollama_unexpected_body"

      {base_url, server_task} =
        start_ollama_server!(~s({"message":{"content":"default client summary"}}))

      assert {:ok, default_client_payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 local_search_config: %{base_url: base_url}
               )

      assert default_client_payload["status"] == "ok"
      assert default_client_payload["summary"] == "default client summary"
      assert default_client_payload["baseUrl"] == base_url
      assert :ok = Task.await(server_task, 5_000)
    after
      File.rm_rf(test_root)
    end
  end

  defp install_fake_commands!(test_root, rg_script, sed_script) do
    fake_bin_dir = Path.join(test_root, "bin")
    File.mkdir_p!(fake_bin_dir)
    write_fake_command!(fake_bin_dir, "rg", rg_script)
    write_fake_command!(fake_bin_dir, "sed", sed_script)
    fake_bin_dir
  end

  defp write_fake_command!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  defp rg_failure_script do
    """
    #!/bin/sh
    exit 2
    """
  end

  defp sed_noop_script do
    """
    #!/bin/sh
    exit 0
    """
  end

  defp rg_timeout_script do
    """
    #!/bin/sh
    sleep 1
    exit 0
    """
  end

  defp rg_excerpt_script do
    """
    #!/bin/sh
    printf '%s\\n' "lib/example.ex:3:"
    printf '%s\\n' "lib/other.ex:5:nonempty search line"
    printf '%s\\n' "malformed line"
    printf '%s\\n' "lib/ignored.ex:not-a-number:skip"
    exit 0
    """
  end

  defp sed_excerpt_script do
    """
    #!/bin/sh
    case "$*" in
      *"README.md"*)
        printf '%s\\n' "requested alpha"
        exit 0
        ;;
      *"missing.txt"*)
        exit 2
        ;;
      *"lib/example.ex"*)
        exit 2
        ;;
      *)
        exit 2
        ;;
    esac
    """
  end

  defp rg_single_hit_script do
    """
    #!/bin/sh
    printf '%s\\n' "lib/example.ex:3:needle line"
    exit 0
    """
  end

  defp sed_timeout_script do
    """
    #!/bin/sh
    sleep 1
    exit 0
    """
  end

  defp start_ollama_server!(response_body) when is_binary(response_body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        _ = :gen_tcp.recv(socket, 0, 5_000)
        response = ollama_http_response(response_body)
        :ok = :gen_tcp.send(socket, response)
        :ok = :gen_tcp.close(socket)
        :ok = :gen_tcp.close(listener)
      end)

    {"http://127.0.0.1:#{port}", task}
  end

  defp ollama_http_response(body) when is_binary(body) do
    "HTTP/1.1 200 OK\r\n" <>
      "content-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n\r\n" <>
      body
  end
end
