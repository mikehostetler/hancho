root = Path.expand("..", __DIR__)
hancho = Path.join(root, "hancho")

{version, 0} = System.cmd(hancho, ["--version"], cd: root, stderr_to_stdout: true)

unless Regex.match?(~r/^\d+\.\d+\.\d+\n$/, version) do
  raise "unexpected Hancho version output: #{inspect(version)}"
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
after
  File.rm_rf!(repository)
end

IO.puts("Hancho escript smoke test passed")
