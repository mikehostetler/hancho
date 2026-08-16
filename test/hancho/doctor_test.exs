defmodule Hancho.DoctorTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{Doctor, Repository}

  test "reports required local checks" do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)

    result = Doctor.run(repository)
    assert result.result == "ok"
    assert Enum.all?(Enum.filter(result.checks, & &1.required), &(&1.status == "pass"))
    assert Enum.find(result.checks, &(&1.name == "process_manager")).status == "pass"
  end

  test "identifies an incompatible Erlang runtime and a missing native dependency" do
    root = temporary_git_repository!("doctor-incompatible")
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)

    result =
      Doctor.run(repository,
        otp_release: "26",
        sqlite_executable: "/no/such/hancho-sqlite3"
      )

    assert result.result == "failed"
    assert Enum.find(result.checks, &(&1.name == "erlang")).status == "fail"
    assert Enum.find(result.checks, &(&1.name == "sqlite")).status == "fail"
  end
end
