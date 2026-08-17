defmodule Hancho.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "has explicit help and version commands" do
    assert capture_io(fn -> assert Hancho.CLI.run([]) == 0 end) =~ "Usage:"
    assert capture_io(fn -> assert Hancho.CLI.run(["--help"]) == 0 end) =~ "hancho doctor"
    assert capture_io(fn -> assert Hancho.CLI.run(["--version"]) == 0 end) == "0.1.0\n"
  end

  test "rejects an unknown command" do
    output = capture_io(:stderr, fn -> assert Hancho.CLI.run(["unknown"]) == 2 end)

    assert output ==
             "ERROR: Unknown command: unknown\nRun 'hancho --help' for usage.\n"
  end
end
