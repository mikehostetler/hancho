defmodule Hancho.Host.TmuxTest do
  use Hancho.RepositoryCase, async: false

  alias Hancho.Host.Tmux
  alias Hancho.Repository

  test "uses a stable local session name and gives a useful missing-session action" do
    root = temporary_git_repository!("tmux-name")
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    assert Tmux.session_name(repository) == Tmux.session_name(repository)
    assert Tmux.session_name(repository) =~ ~r/^hancho-[a-z0-9-]+-[a-f0-9]{10}$/
    assert {:error, %{code: :tmux_session_not_found, message: message}} = Tmux.attach(repository)
    assert message =~ "hancho up --tmux"
  end

  test "reports missing tmux and never falls back to nohup" do
    root = temporary_git_repository!("no-tmux")
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    previous = System.get_env("PATH")
    System.put_env("PATH", temporary_directory!("empty-path"))
    on_exit(fn -> System.put_env("PATH", previous) end)

    assert {:error, %{code: :tmux_unavailable, message: message}} = Tmux.start(repository)
    assert message =~ "does not use nohup"
  end
end
