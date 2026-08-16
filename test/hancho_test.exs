defmodule HanchoTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "the CLI prints only its version" do
    assert capture_io(fn -> Hancho.CLI.main([]) end) == "0.1.0\n"
  end
end
