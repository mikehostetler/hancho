defmodule Hancho.ConfigTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{Config, Repository}

  test "loads the default config with a stable hash and sources" do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)

    assert {:ok, config} = Config.load(repository)
    assert String.length(config.hash) == 64
    assert config.data["schema_version"] == 1
    assert config.sources["routes.build.implement"] == config.path
  end

  test "reports independent validation errors" do
    config = %{
      "schema_version" => 9,
      "wip_limit" => 0,
      "default_harness" => "missing",
      "harnesses" => %{},
      "routes" => %{"unknown" => %{"run" => "missing"}}
    }

    assert {:error, error} = Config.validate(config)
    assert error.message =~ "schema_version"
    assert error.message =~ "wip_limit"
    assert error.message =~ "default_harness"
    assert error.message =~ "unknown workflow"
  end

  test "rejects secret values but accepts environment variable names" do
    base = %{
      "schema_version" => 1,
      "wip_limit" => 1,
      "default_harness" => "fake",
      "harnesses" => %{
        "fake" => %{
          "adapter" => "builtin:fake",
          "command" => "fake",
          "capabilities" => ["read"],
          "api_token" => "actual-secret"
        }
      },
      "routes" => %{}
    }

    assert {:error, error} = Config.validate(base)
    assert error.message =~ "environment variable"

    assert :ok =
             Config.validate(put_in(base, ["harnesses", "fake", "api_token"], "FAKE_API_TOKEN"))
  end

  test "rejects an unknown station route and a harness without its required capability" do
    config = %{
      "schema_version" => 1,
      "wip_limit" => 1,
      "default_harness" => "reader",
      "harnesses" => %{
        "reader" => %{
          "adapter" => "builtin:fake",
          "command" => "fake",
          "capabilities" => ["read"]
        }
      },
      "routes" => %{
        "build" => %{"implement" => "reader", "unknown" => "reader"}
      }
    }

    assert {:error, error} = Config.validate(config)
    assert error.message =~ "unknown station route"
    assert error.message =~ "requires capability edit_worktree"
  end

  test "uses the configuration schema for nested value types" do
    config = %{
      "schema_version" => 1,
      "wip_limit" => 1,
      "default_harness" => "fake",
      "harnesses" => %{
        "fake" => %{
          "adapter" => "builtin:fake",
          "command" => 42,
          "capabilities" => ["read"]
        }
      },
      "routes" => %{}
    }

    assert {:error, error} = Config.validate(config)
    assert error.message =~ "harnesses.fake.command invalid type: expected string"
  end
end
