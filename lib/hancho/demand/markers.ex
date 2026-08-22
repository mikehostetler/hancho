defmodule Hancho.Demand.Markers do
  @moduledoc "Canonical cross-system mapping markers."

  alias Hancho.Beadwork.Issue, as: BeadworkIssue
  alias Hancho.GitHub.Issue, as: GitHubIssue

  @github_url ~r/^Hancho-GitHub-(?:Issue|Sub-Issue):\s+(\S+)$/m
  @github_node ~r/^Hancho-GitHub-Node:\s+(\S+)$/m
  @beadwork_id ~r/^Hancho-Beadwork-(?:Epic|Task):\s+(\S+)$/m

  @spec beadwork_text(GitHubIssue.t()) :: String.t()
  def beadwork_text(%GitHubIssue{} = issue) do
    label = if issue.parent_node_id, do: "Sub-Issue", else: "Issue"
    "Hancho-GitHub-#{label}: #{issue.url}\nHancho-GitHub-Node: #{issue.node_id}"
  end

  @spec github_text(GitHubIssue.t(), String.t()) :: String.t()
  def github_text(%GitHubIssue{} = issue, beadwork_id) do
    label = if issue.parent_node_id, do: "Task", else: "Epic"
    "Hancho-Beadwork-#{label}: #{beadwork_id}"
  end

  @spec github_urls(BeadworkIssue.t()) :: [String.t()]
  def github_urls(%BeadworkIssue{} = issue), do: captures(beadwork_texts(issue), @github_url)

  @spec github_nodes(BeadworkIssue.t()) :: [String.t()]
  def github_nodes(%BeadworkIssue{} = issue), do: captures(beadwork_texts(issue), @github_node)

  @spec beadwork_ids(GitHubIssue.t()) :: [String.t()]
  def beadwork_ids(%GitHubIssue{} = issue), do: captures(issue.comments, @beadwork_id)

  @spec mapped_task?(BeadworkIssue.t()) :: boolean()
  def mapped_task?(%BeadworkIssue{type: "task"} = issue),
    do: github_urls(issue) != [] and github_nodes(issue) != [] and is_binary(issue.parent)

  def mapped_task?(_issue), do: false

  @spec mapped_epic?(BeadworkIssue.t()) :: boolean()
  def mapped_epic?(%BeadworkIssue{type: "epic", parent: nil} = issue),
    do: github_urls(issue) != [] and github_nodes(issue) != []

  def mapped_epic?(_issue), do: false

  defp beadwork_texts(issue) do
    [issue.description | Enum.map(issue.comments, &comment_text/1)]
  end

  defp comment_text(%{"text" => text}) when is_binary(text), do: text
  defp comment_text(%{text: text}) when is_binary(text), do: text
  defp comment_text(text) when is_binary(text), do: text
  defp comment_text(_value), do: ""

  defp captures(texts, regex) do
    texts
    |> Enum.flat_map(fn text -> Regex.scan(regex, text, capture: :all_but_first) end)
    |> List.flatten()
    |> Enum.uniq()
  end
end
