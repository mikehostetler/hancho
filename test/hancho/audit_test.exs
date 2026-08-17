defmodule Hancho.AuditTest do
  use ExUnit.Case, async: true

  test "contains audit writer failures" do
    dead_writer = spawn(fn -> :ok end)
    monitor = Process.monitor(dead_writer)
    assert_receive {:DOWN, ^monitor, :process, ^dead_writer, :normal}

    assert :ok = Hancho.Audit.write(dead_writer, "factory work continues")
    assert :ok = Hancho.Audit.close(dead_writer)
  end

  test "falls back to disabled audit delivery when configuration is invalid" do
    root = Path.join(System.tmp_dir!(), "hancho-audit-#{System.unique_integer([:positive])}")
    project = Hancho.Project.new(root)
    File.mkdir_p!(project.hancho_dir)
    File.write!(project.config_path, "not valid = [toml")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, :disabled} = Hancho.Audit.open(project)
  end
end
