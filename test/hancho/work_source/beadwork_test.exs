defmodule Hancho.WorkSource.BeadworkTest do
  use Hancho.RepositoryCase, async: false

  @moduletag :integration

  alias Hancho.WorkSource.Beadwork
  alias Hancho.{Config, Journal, Repository}

  setup do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    {:ok, config} = Config.load(repository)
    definition = Hancho.Workflows.WalkingSkeleton.V1.definition()
    {:ok, work_order} = Journal.create_work_order(repository, config, definition, "bw-work")
    fixture_root = temporary_directory!("bw")
    log = Path.join(fixture_root, "calls.log")
    command = beadwork_fixture!(fixture_root, log, :success)
    old = System.get_env("HANCHO_BW")
    System.put_env("HANCHO_BW", command)
    on_exit(fn -> restore_env("HANCHO_BW", old) end)
    %{repository: repository, run_id: work_order["id"], log: log, fixture_root: fixture_root}
  end

  test "selects ready work in stable order and applies only and max", context do
    assert {:ok, ready} = Beadwork.ready(context.repository, max: 2)
    assert Enum.map(ready, & &1["id"]) == ["bw-first", "bw-second"]
    assert {:ok, [%{"id" => "bw-second"}]} = Beadwork.ready(context.repository, only: "bw-second")

    direct = [
      %{"id" => "closed", "status" => "closed", "ordinal" => 0},
      %{"id" => "blocked", "status" => "open", "ordinal" => 1, "blocked" => true},
      %{"id" => "ready", "status" => "open", "ordinal" => 2}
    ]

    assert Enum.map(Beadwork.select(direct, []), & &1["id"]) == ["ready"]

    assert Enum.map(Beadwork.select(direct, include_closed: true), & &1["id"]) == [
             "closed",
             "ready"
           ]
  end

  test "applies inclusive ranges and explains a dry-run selection" do
    items = [
      %{"id" => "one", "status" => "open", "ordinal" => 1},
      %{"id" => "two", "status" => "open", "ordinal" => 2},
      %{"id" => "three", "status" => "open", "ordinal" => 3},
      %{"id" => "four", "status" => "closed", "ordinal" => 4},
      %{"id" => "five", "status" => "open", "ordinal" => 5, "blocked" => true}
    ]

    view = Beadwork.selection_view(items, start_at: "two", end_at: "five", max: 2, dry_run: true)
    assert view.dry_run
    assert Enum.map(view.selected, & &1["id"]) == ["two", "three"]
    assert Enum.find(view.explanations, &(&1.id == "four")).reason == "closed"
    assert Enum.find(view.explanations, &(&1.id == "five")).reason == "open blocker"
  end

  test "claims only once for one idempotency key", context do
    assert {:ok, first} = Beadwork.claim(context.repository, context.run_id, "bw-first")
    assert first["status"] == "confirmed"
    assert {:ok, second} = Beadwork.claim(context.repository, context.run_id, "bw-first")
    assert second["id"] == first["id"]

    calls = File.read!(context.log)
    assert length(Regex.scan(~r/ start bw-first /, calls)) == 1
  end

  test "records link, discovered child, close, and sync results", context do
    assert {:ok, %{"status" => "confirmed"}} =
             Beadwork.link_github(
               context.repository,
               context.run_id,
               "bw-first",
               "https://github.com/example/project/issues/1"
             )

    assert {:ok, %{"status" => "confirmed"}} =
             Beadwork.create_discovered(
               context.repository,
               context.run_id,
               "bw-first",
               %{"title" => "Small child", "evidence" => %{"path" => "lib/one.ex"}}
             )

    assert {:ok, closed} =
             Beadwork.close(context.repository, context.run_id, "bw-first", "Accepted candidate")

    assert closed["status"] == "confirmed"
    assert closed["sync"] == "confirmed"
  end

  test "makes an uncertain effect visible after a failed write", context do
    command = beadwork_fixture!(context.fixture_root, context.log, :fail_start)
    System.put_env("HANCHO_BW", command)

    assert {:ok, effect} = Beadwork.claim(context.repository, context.run_id, "bw-second")
    assert effect["status"] == "uncertain"

    assert {:error, %{code: :effect_not_retryable}} =
             Beadwork.claim(context.repository, context.run_id, "bw-second")
  end

  defp beadwork_fixture!(root, log, mode) do
    path = Path.join(root, "bw-#{mode}")
    fail_start = if mode == :fail_start, do: "[ \"$command\" = start ] && exit 9", else: ":"

    File.write!(
      path,
      """
      #!/bin/sh
      printf ' %s \n' "$*" >> '#{log}'
      if [ "$1" = -C ]; then shift 2; fi
      command="$1"; shift
      #{fail_start}
      case "$command" in
        ready) printf '[{"id":"bw-second","status":"open","ordinal":2},{"id":"bw-first","status":"open","ordinal":1}]\n' ;;
        list) printf '[]\n' ;;
        show) printf '{"id":"%s","status":"open"}\n' "$1" ;;
        start) printf '{"id":"%s","status":"in_progress"}\n' "$1" ;;
        close) printf '{"id":"%s","status":"closed"}\n' "$1" ;;
        comment) printf '{"id":"%s","commented":true}\n' "$1" ;;
        create) printf '{"id":"bw-child","status":"open"}\n' ;;
        sync) printf 'synced\n' ;;
        *) exit 64 ;;
      esac
      """
    )

    File.chmod!(path, 0o700)
    path
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
