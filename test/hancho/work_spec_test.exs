defmodule Hancho.WorkSpecTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{JSON, WorkSpec}

  test "loads a bounded JSON work specification" do
    root = temporary_directory!()
    path = Path.join(root, "spec.json")
    File.write!(path, JSON.encode!(Hancho.BuildFixture.spec("work-1")))

    assert {:ok, spec} = WorkSpec.load("work-1", spec_path: path)
    assert spec.allowed_scopes == ["lib/"]
    assert spec.profile == "elixir_library"
  end

  test "rejects missing, mismatched, unsafe, and invalid scope" do
    assert {:error, %{code: :work_spec_required}} = WorkSpec.load("work-1")

    invalid = Hancho.BuildFixture.spec("other", ["../outside", ".git/config"])
    assert {:error, error} = WorkSpec.load("work-1", work_spec: invalid)
    assert error.message =~ "id must match"
    assert error.message =~ "unsafe path"
  end
end
