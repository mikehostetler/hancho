defmodule Hancho.GitHubCLI do
  @moduledoc false

  alias Hancho.{Error, Repository}

  def command(%Repository{} = repository, arguments) do
    command = System.get_env("HANCHO_GH") || "gh"

    case System.cmd(command, arguments, cd: repository.root, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} ->
        {:error,
         %Error{
           code: :github_failed,
           exit_status: 69,
           message: "GitHub command failed with status #{status}: #{String.trim(output)}",
           details: %{arguments: arguments, status: status}
         }}
    end
  rescue
    error ->
      {:error,
       %Error{code: :github_unavailable, exit_status: 69, message: Exception.message(error)}}
  end
end
