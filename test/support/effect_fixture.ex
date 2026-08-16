defmodule Hancho.EffectFixture do
  alias Hancho.{Config, Git, Journal, Repository, SQLite, Store}

  def candidate_work_order!(root) do
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    {:ok, config} = Config.load(repository)
    definition = Hancho.Workflows.Build.V1.definition()
    {:ok, baseline} = Git.command(root, ["rev-parse", "HEAD"])
    {:ok, tree} = Git.command(root, ["rev-parse", "#{baseline}^{tree}"])

    {:ok, candidate} =
      Git.command(root, ["commit-tree", tree, "-p", baseline, "-m", "Fixture candidate"])

    {:ok, work_order} =
      Journal.create_work_order(repository, config, definition, "fixture-work", %{
        baseline_commit: baseline,
        target_branch: "main"
      })

    :ok =
      SQLite.execute(
        Store.path(repository),
        "UPDATE work_orders SET state = 'candidate_ready', status = 'complete' WHERE id = #{SQLite.quote(work_order["id"])};"
      )

    :ok = Git.retain_candidate(repository, work_order["id"], candidate)
    {:ok, work_order} = Journal.get_work_order(repository, work_order["id"])
    %{repository: repository, work_order: work_order, baseline: baseline, candidate: candidate}
  end

  def bare_remote!(root) do
    remote = Path.join(Hancho.RepositoryCase.temporary_directory!("remote"), "origin.git")
    {_output, 0} = System.cmd("git", ["init", "--bare", "-q", remote])
    {_output, 0} = System.cmd("git", ["-C", root, "remote", "add", "origin", remote])
    {_output, 0} = System.cmd("git", ["-C", root, "push", "-q", "origin", "main:main"])
    remote
  end
end
