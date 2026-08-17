defmodule Hancho.BeadworkTest do
  use ExUnit.Case, async: true

  alias Hancho.Command.Result

  defmodule Command do
    def run("/test/bw", ["--version"], options) do
      send(self(), {:options, options})
      {:ok, %Result{stdout: "bw 1.2.3\n", stderr: "", exit_status: 0}}
    end

    def run("/test/bw", ["config", "list"], _options) do
      {:ok, %Result{stdout: "not initialized\n", stderr: "", exit_status: 1}}
    end

    def run("/test/bw", ["show", "hancho-123", "--json"], _options) do
      {:ok,
       %Result{
         stdout: ~s({"id":"hancho-123","status":"open"}) <> "\n",
         stderr: "",
         exit_status: 0
       }}
    end
  end

  test "returns trimmed version output through the command boundary" do
    assert Hancho.Beadwork.version(
             executable: "/test/bw",
             command: Command,
             working_dir: "/repo"
           ) == {:ok, "bw 1.2.3"}

    assert_received {:options, [cwd: "/repo", stderr_to_stdout: true]}
  end

  test "returns command output and status on failure" do
    assert Hancho.Beadwork.repository_config(executable: "/test/bw", command: Command) ==
             {:error, {"not initialized", 1}}
  end

  test "decodes issue command output as JSON" do
    assert Hancho.Beadwork.show("hancho-123", executable: "/test/bw", command: Command) ==
             {:ok, %{"id" => "hancho-123", "status" => "open"}}
  end
end
