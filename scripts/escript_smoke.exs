root = Path.expand("..", __DIR__)
hancho = Path.join(root, "hancho")

{version, 0} = System.cmd(hancho, ["--version"], cd: root, stderr_to_stdout: true)

unless Regex.match?(~r/^\d+\.\d+\.\d+\n$/, version) do
  raise "unexpected Hancho version output: #{inspect(version)}"
end

{short_version, 0} = System.cmd(hancho, ["-v"], cd: root, stderr_to_stdout: true)

unless short_version == version do
  raise "short version option did not match --version"
end

{invalid_option, 2} = System.cmd(hancho, ["--invalid"], cd: root, stderr_to_stdout: true)

unless invalid_option =~ "Unknown option: --invalid" do
  raise "invalid option did not report an error"
end

{unknown, 2} = System.cmd(hancho, ["unknown"], cd: root, stderr_to_stdout: true)

unless unknown =~ "Unknown command" do
  raise "unknown command did not report an error"
end

{doctor, _status} = System.cmd(hancho, ["doctor"], cd: root, stderr_to_stdout: true)

for expected <- ["PASS git:", "PASS repository:", "PASS config:"] do
  unless doctor =~ expected do
    raise "doctor output does not contain #{inspect(expected)}"
  end
end

repository =
  Path.join(System.tmp_dir!(), "hancho-escript-#{System.unique_integer([:positive])}")

try do
  File.mkdir_p!(repository)
  {_output, 0} = System.cmd("git", ["init", repository], stderr_to_stdout: true)
  {output, 0} = System.cmd(hancho, ["init"], cd: repository, stderr_to_stdout: true)

  unless output =~ "Initialized Hancho" do
    raise "init did not report success"
  end

  config = File.read!(Path.join(repository, ".hancho/config.toml"))

  unless config =~ "version = 1" and config =~ "[repo]" and config =~ "[logs]" do
    raise "init did not write the default configuration"
  end

  {run_output, 1} =
    System.cmd(hancho, ["run", "implement", "missing-issue"],
      cd: repository,
      stderr_to_stdout: true
    )

  unless run_output =~ "stopped at preflight" do
    raise "workflow did not report its stopped step"
  end

  unless File.exists?(Path.join(repository, ".hancho/hancho.sqlite3")) do
    raise "escript workflow did not create its SQLite database"
  end

  native_libraries =
    Path.wildcard(Path.join(repository, ".hancho/native/exqlite/priv/sqlite3_nif.*"))

  unless native_libraries != [] do
    raise "escript workflow did not extract the Exqlite native library"
  end
after
  File.rm_rf!(repository)
end

IO.puts("Hancho escript smoke test passed")
