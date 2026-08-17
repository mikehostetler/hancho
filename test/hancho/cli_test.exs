defmodule Hancho.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "has explicit help and version commands" do
    assert capture_io(fn -> assert Hancho.CLI.run([]) == 0 end) =~ "Usage:"
    assert capture_io(fn -> assert Hancho.CLI.run(["--help"]) == 0 end) =~ "hancho doctor"
    assert capture_io(fn -> assert Hancho.CLI.run(["-h"]) == 0 end) =~ "hancho doctor"
    assert capture_io(fn -> assert Hancho.CLI.run(["--version"]) == 0 end) == "0.1.0\n"
    assert capture_io(fn -> assert Hancho.CLI.run(["-v"]) == 0 end) == "0.1.0\n"
    assert capture_io(fn -> assert Hancho.CLI.run(["help"]) == 0 end) =~ "Usage:"
    assert capture_io(fn -> assert Hancho.CLI.run(["version"]) == 0 end) == "0.1.0\n"
  end

  test "parses global options after a command" do
    assert capture_io(fn -> assert Hancho.CLI.run(["doctor", "--help"]) == 0 end) =~ "Usage:"
  end

  test "rejects an unknown command" do
    output = capture_io(:stderr, fn -> assert Hancho.CLI.run(["unknown"]) == 2 end)

    assert output ==
             "ERROR: Unknown command: unknown\nRun 'hancho --help' for usage.\n"
  end

  test "rejects unknown options" do
    output = capture_io(:stderr, fn -> assert Hancho.CLI.run(["--unknown"]) == 2 end)

    assert output ==
             "ERROR: Unknown option: --unknown\nRun 'hancho --help' for usage.\n"
  end

  test "rejects extra command arguments" do
    output = capture_io(:stderr, fn -> assert Hancho.CLI.run(["doctor", "extra"]) == 2 end)

    assert output ==
             "ERROR: Unknown command: doctor extra\nRun 'hancho --help' for usage.\n"
  end
end
