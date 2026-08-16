defmodule Hancho.Doctor do
  @moduledoc false

  alias Hancho.Harness.Router
  alias Hancho.Workflow.Registry
  alias Hancho.{Config, Repository, SQLite, Store}

  @spec run(Repository.t(), keyword()) :: map()
  def run(repository, options \\ []) do
    sqlite = Keyword.get(options, :sqlite_executable, SQLite.executable())
    otp_release = Keyword.get(options, :otp_release, current_otp_release())

    checks = [
      command_check("git", "git", true),
      command_check("sqlite", sqlite, true),
      erlang_check(otp_release),
      runtime_check(repository),
      config_check(repository),
      workflow_check(),
      route_check(repository),
      database_check(repository),
      command_check("tmux", "tmux", false),
      command_check("beadwork", "bw", false),
      command_check("github", "gh", false)
    ]

    required_failure? = Enum.any?(checks, &(&1.required and &1.status == "fail"))
    %{result: if(required_failure?, do: "failed", else: "ok"), checks: checks}
  end

  defp command_check(name, command, required) do
    executable = System.find_executable(command)

    if executable do
      %{name: name, status: "pass", required: required, detail: executable}
    else
      %{
        name: name,
        status: if(required, do: "fail", else: "warning"),
        required: required,
        detail: "Command '#{command}' was not found."
      }
    end
  end

  defp runtime_check(repository) do
    if File.dir?(repository.runtime_dir) do
      %{name: "runtime", status: "pass", required: true, detail: repository.runtime_dir}
    else
      %{name: "runtime", status: "fail", required: true, detail: "Run 'hancho init'."}
    end
  end

  defp erlang_check(release) do
    major = release |> String.split(".") |> hd() |> String.to_integer()

    if major in 27..29 do
      %{
        name: "erlang",
        status: "pass",
        required: true,
        detail: "OTP #{release} is supported (27 through 29)."
      }
    else
      %{
        name: "erlang",
        status: "fail",
        required: true,
        detail: "OTP #{release} is incompatible. Install OTP 27, 28, or 29."
      }
    end
  end

  defp current_otp_release, do: :erlang.system_info(:otp_release) |> List.to_string()

  defp config_check(repository) do
    case Config.load(repository) do
      {:ok, config} -> %{name: "config", status: "pass", required: true, detail: config.hash}
      {:error, error} -> %{name: "config", status: "fail", required: true, detail: error.message}
    end
  end

  defp database_check(repository) do
    case Store.migrate(Store.path(repository)) do
      :ok ->
        %{
          name: "database",
          status: "pass",
          required: true,
          detail: "schema #{Store.schema_version()}"
        }

      {:error, error} ->
        %{name: "database", status: "fail", required: true, detail: error.message}
    end
  end

  defp workflow_check do
    case Registry.validate_all() do
      :ok ->
        %{
          name: "workflows",
          status: "pass",
          required: true,
          detail: "#{length(Registry.list())} installed"
        }

      {:error, errors} ->
        %{name: "workflows", status: "fail", required: true, detail: Enum.join(errors, "; ")}
    end
  end

  defp route_check(repository) do
    with {:ok, config} <- Config.load(repository),
         :ok <- Router.validate_routes(config, Registry.list()) do
      %{
        name: "routes",
        status: "pass",
        required: true,
        detail: "All installed workflow stations have compatible harnesses."
      }
    else
      {:error, error} -> %{name: "routes", status: "fail", required: true, detail: error.message}
    end
  end
end
