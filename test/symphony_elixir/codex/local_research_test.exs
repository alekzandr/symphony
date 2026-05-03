defmodule SymphonyElixir.Codex.LocalResearchTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.LocalResearch

  test "search/2 returns local excerpts and a single Ollama summary call" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-research-happy-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "README.md"), "requested path alpha\n")
      File.write!(Path.join(workspace, "lib/example.ex"), "defmodule Example do\n  # needle\nend\n")

      test_pid = self()

      assert {:ok, payload} =
               LocalResearch.search(
                 %{"query" => "needle", "paths" => ["README.md"]},
                 workspace: workspace,
                 ollama_client: fn url, request, timeout_ms ->
                   send(test_pid, {:ollama_client_called, url, request, timeout_ms})
                   {:ok, %{"message" => %{"content" => "workspace summary"}}}
                 end
               )

      assert_received {:ollama_client_called, "http://127.0.0.1:11434/api/chat", request, 15_000}
      assert request["model"] == "gemma4:e2b"
      assert request["stream"] == false

      assert payload["status"] == "ok"
      assert payload["summary"] == "workspace summary"
      assert payload["requestedPaths"] == ["README.md"]
      assert payload["workerHost"] == nil
      assert Enum.map(payload["sources"], & &1["kind"]) == ["requested", "search"]
      assert Enum.map(payload["sources"], & &1["path"]) == ["README.md", "lib/example.ex"]
      assert [requested, search] = payload["sources"]
      assert requested["excerpt"] =~ "requested path alpha"
      assert search["excerpt"] =~ "needle"
    after
      File.rm_rf(test_root)
    end
  end

  test "search/2 returns no_results without calling Ollama when the workspace has no matches" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-research-no-results-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      assert {:ok, payload} =
               LocalResearch.search(
                 "nothing-to-see-here",
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   flunk("ollama client should not be called when there are no workspace matches")
                 end
               )

      assert payload["status"] == "no_results"
      assert payload["summary"] == "No matching files were found for `nothing-to-see-here`."
      assert payload["sources"] == []
      assert payload["ollama"]["status"] == "no_results"
    after
      File.rm_rf(test_root)
    end
  end

  test "search/2 falls back gracefully when Ollama is unavailable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-research-fallback-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "notes.txt"), "needle in a haystack\n")

      assert {:ok, payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:error, :boom}
                 end
               )

      assert payload["status"] == "fallback"
      assert payload["summary"] =~ "Local Ollama summary unavailable."
      assert payload["sources"] |> Enum.map(& &1["path"]) == ["notes.txt"]
      assert payload["ollama"]["status"] == "fallback"
      assert payload["ollama"]["reason"] == ":boom"
    after
      File.rm_rf(test_root)
    end
  end

  test "search/2 uses ssh when a worker host is provided" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-local-research-ssh-#{System.unique_integer([:positive])}"
      )

    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
    end)

    try do
      workspace = Path.join(test_root, "workspace")
      install_fake_ssh!(test_root, trace_file)
      File.mkdir_p!(workspace)

      assert {:ok, payload} =
               LocalResearch.search(
                 "needle",
                 workspace: workspace,
                 worker_host: "worker-a",
                 ollama_client: fn _url, _request, _timeout_ms ->
                   {:ok, %{"message" => %{"content" => "remote summary"}}}
                 end
               )

      assert payload["workerHost"] == "worker-a"
      assert payload["status"] == "ok"
      assert payload["summary"] == "remote summary"

      trace = File.read!(trace_file)
      assert trace =~ "-T worker-a bash -lc"
      assert trace =~ "worker-a bash -lc"
      assert trace =~ "rg -n -i -F --hidden"
      assert trace =~ "sed -n"
    after
      File.rm_rf(test_root)
    end
  end

  defp install_fake_ssh!(test_root, trace_file) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(
      fake_ssh,
      """
      #!/bin/sh
      printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"

      case "$*" in
        *"rg -n -i -F --hidden"*)
          printf '%s\\n' "lib/example.ex:3:needle line"
          ;;
        *"sed -n"*)
          printf '%s\\n' "alpha"
          printf '%s\\n' "beta"
          printf '%s\\n' "needle line"
          printf '%s\\n' "omega"
          ;;
      esac

      exit 0
      """
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end
end
