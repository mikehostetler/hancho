defmodule Hancho.BuildRunner do
  @moduledoc "Executes Build.V1 with Git, verification, review, and receipt controls."

  alias Hancho.Harness.{Executor, Router}
  alias Hancho.Workflow.{Event, Registry}

  alias Hancho.{
    Artifacts,
    Config,
    Error,
    Gates,
    Git,
    Journal,
    JSON,
    Repository,
    Verification,
    WorkSpec
  }

  @spec run(Repository.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(repository, work_ref, options \\ []) do
    with {:ok, config} <- Config.load(repository),
         {:ok, definition} <- Registry.fetch("build", 1),
         {:ok, spec} <- WorkSpec.load(work_ref, options),
         {:ok, preflight} <- Git.preflight(repository),
         {:ok, work_order} <-
           Journal.create_work_order(repository, config, definition, work_ref, %{
             actor: actor(),
             reason: "Build work order submitted",
             baseline_commit: preflight.baseline,
             target_branch: preflight.branch
           }),
         :ok <- store_work_references(repository, work_order["id"], spec),
         {:ok, _spec_artifact} <-
           Artifacts.write(
             repository,
             work_order["id"],
             "work_spec",
             "work-spec.json",
             JSON.encode!(WorkSpec.to_map(spec)),
             media_type: "application/json",
             retention: "durable"
           ),
         {:ok, started} <-
           transition(repository, work_order, definition, "start", "Build work released"),
         {:ok, worktree} <-
           Git.prepare_worktree(repository, work_order["id"], preflight.baseline) do
      context = %{
        repository: repository,
        config: config,
        definition: definition,
        spec: spec,
        work_order: started.work_order,
        worktree: worktree,
        baseline: preflight.baseline,
        branch: preflight.branch,
        approvals: [],
        approval_records: [],
        max_repairs: get_in(config.data, ["limits", "max_fix_attempts"]) || 2,
        options: options,
        implementation: nil
      }

      implement(context)
    end
  end

  @spec resume(Repository.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume(repository, run_id) do
    with {:ok, work_order} <- Journal.get_work_order(repository, run_id) do
      case work_order["state"] do
        "awaiting_acceptance" -> resume_candidate_acceptance(repository, work_order)
        _ -> resume_gate(repository, run_id)
      end
    end
  end

  defp resume_gate(repository, run_id) do
    with {:ok, config} <- Config.load(repository),
         {:ok, definition} <- Registry.fetch("build", 1),
         {:ok, work_order} <- Journal.get_work_order(repository, run_id),
         :ok <- resumable_gate_stop(repository, work_order),
         {:ok, spec} <- load_stored_spec(repository, work_order),
         {:ok, decisions} <- approved_decisions(repository, run_id),
         {:ok, resumed} <-
           Journal.transition(
             repository,
             run_id,
             definition,
             %Event{
               name: "resume_requested",
               expected_state: "stopped",
               actor: actor(),
               reason: "Approved gate permits safe resume"
             }
           ) do
      context = %{
        repository: repository,
        config: config,
        definition: definition,
        spec: spec,
        work_order: resumed.work_order,
        worktree: work_order["worktree_path"],
        baseline: work_order["baseline_commit"],
        branch: work_order["target_branch"],
        approvals: Enum.map(decisions, & &1["kind"]),
        approval_records: decisions,
        max_repairs: get_in(config.data, ["limits", "max_fix_attempts"]) || 2,
        options: [],
        implementation: nil
      }

      with {:ok, paths} <- Git.changed_paths(context.worktree),
           :ok <- Git.verify_scope(paths, context.spec.allowed_scopes),
           :ok <- gates(context, paths),
           {:ok, next} <-
             transition(
               context.repository,
               context.work_order,
               context.definition,
               "implementation_ready",
               "Approved implementation is ready for checks"
             ) do
        verify(%{context | work_order: next.work_order}, 0)
      else
        {:error, error} -> stop(context, error)
      end
    end
  end

  defp resume_candidate_acceptance(repository, work_order) do
    with {:ok, definition} <- Registry.fetch("build", work_order["workflow_version"]),
         {:ok, decisions} <- candidate_acceptance_decisions(repository, work_order["id"]),
         decision when is_map(decision) <- List.first(decisions),
         {:ok, candidate} <-
           Git.command(
             repository.root,
             ["rev-parse", "--verify", "refs/hancho/candidates/#{work_order["id"]}^{commit}"]
           ),
         {:ok, receipt} <- candidate_receipt(repository, work_order["id"]),
         :ok <- candidate_decision_matches(decision, candidate, receipt),
         :ok <- candidate_worktree_safe(repository, work_order, candidate) do
      if decision["status"] == "approved" do
        with {:ok, accepted} <-
               Journal.transition(
                 repository,
                 work_order["id"],
                 definition,
                 %Event{
                   name: "candidate_approved",
                   expected_state: "awaiting_acceptance",
                   actor: decision["actor"],
                   reason: decision["reason"]
                 },
                 %{
                   artifacts: ["candidate_receipt"],
                   decisions: %{"candidate_acceptance" => "approved"}
                 }
               ),
             :ok <- Git.remove_worktree(repository, work_order["worktree_path"]) do
          {:ok,
           %{
             work_order: accepted.work_order,
             candidate_commit: candidate,
             receipt: receipt,
             decision: decision
           }}
        end
      else
        with {:ok, rejected} <-
               Journal.transition(
                 repository,
                 work_order["id"],
                 definition,
                 %Event{
                   name: "candidate_rejected",
                   expected_state: "awaiting_acceptance",
                   actor: decision["actor"],
                   reason: decision["reason"]
                 }
               ) do
          {:ok,
           %{work_order: rejected.work_order, candidate_commit: candidate, decision: decision}}
        end
      end
    else
      nil ->
        {:error,
         error(
           :candidate_acceptance_required,
           "The exact candidate needs an approved or rejected candidate_acceptance decision."
         )}

      {:error, failure} ->
        {:error, failure}
    end
  end

  defp candidate_acceptance_decisions(repository, run_id) do
    Hancho.SQLite.query(
      Hancho.Store.path(repository),
      "SELECT * FROM decisions WHERE run_id = #{Hancho.SQLite.quote(run_id)} AND kind = 'candidate_acceptance' AND status IN ('approved', 'rejected') ORDER BY decided_at DESC, id DESC;"
    )
  end

  defp candidate_receipt(repository, run_id) do
    with {:ok, artifacts} <- Artifacts.list(repository, run_id) do
      case Enum.find(artifacts, fn artifact ->
             artifact["kind"] == "receipt" and
               String.ends_with?(artifact["relative_path"], "/receipts/candidate.json")
           end) do
        nil -> {:error, error(:candidate_receipt_missing, "Candidate receipt is missing.")}
        receipt -> {:ok, receipt}
      end
    end
  end

  defp candidate_decision_matches(%{"status" => "rejected"}, _candidate, _receipt), do: :ok

  defp candidate_decision_matches(decision, candidate, receipt) do
    request = JSON.decode!(decision["request_json"] || "{}")

    if request["candidate_commit"] == candidate and
         request["receipt_hash"] == receipt["content_hash"] do
      :ok
    else
      {:error,
       error(
         :candidate_acceptance_stale,
         "Candidate acceptance does not name the current candidate and receipt hash."
       )}
    end
  end

  defp candidate_worktree_safe(repository, work_order, candidate) do
    with path when is_binary(path) <- work_order["worktree_path"],
         true <- File.dir?(path),
         :ok <- Git.assert_head(path, candidate),
         {:ok, []} <- Git.changed_paths(path),
         :ok <- Git.assert_target_unchanged(repository, work_order["baseline_commit"]) do
      :ok
    else
      _ ->
        {:error,
         error(
           :candidate_acceptance_state_changed,
           "Candidate worktree or target changed while human acceptance was pending."
         )}
    end
  end

  defp implement(context) do
    case Executor.run_station(
           context.repository,
           context.config,
           context.definition,
           context.work_order,
           "implement",
           implementation_prompt(context),
           worktree_path: context.worktree,
           model: Keyword.get(context.options, :model)
         ) do
      {:ok, %{result: %{status: "success"}} = implementation} ->
        context = %{context | implementation: implementation}

        with :ok <- Git.assert_head(context.worktree, context.baseline),
             {:ok, paths} <- Git.changed_paths(context.worktree),
             :ok <- Git.verify_scope(paths, context.spec.allowed_scopes),
             :ok <- gates(context, paths),
             {:ok, next} <-
               transition(
                 context.repository,
                 context.work_order,
                 context.definition,
                 "implementation_ready",
                 "Implementation is ready for checks"
               ) do
          verify(%{context | work_order: next.work_order}, 0)
        else
          {:error, error} -> stop(context, error)
        end

      {:ok, execution} ->
        stop(
          context,
          error(
            :harness_failed,
            "Implementation harness ended with '#{execution.result.status}'."
          )
        )

      {:error, error} ->
        stop(context, error)
    end
  end

  defp verify(context, repair_attempt) do
    commands = Verification.commands(context.spec.profile, context.spec.checks)

    with {:ok, paths} <- Git.changed_paths(context.worktree),
         :ok <- Git.verify_scope(paths, context.spec.allowed_scopes),
         {:ok, checks} <-
           Verification.run(
             context.repository,
             context.work_order["id"],
             context.worktree,
             commands,
             round: repair_attempt + 1
           ) do
      if checks.passed do
        create_and_check_candidate(context, repair_attempt, checks)
      else
        repair_or_stop(context, repair_attempt, checks)
      end
    else
      {:error, error} ->
        repair_or_stop(context, repair_attempt, %{error: Exception.message(error)})
    end
  end

  defp create_and_check_candidate(context, repair_attempt, precommit_checks) do
    with {:ok, candidate} <-
           Git.create_candidate(
             context.worktree,
             context.baseline,
             context.work_order["id"],
             context.spec.title,
             context.work_order["work_ref"]
           ),
         {:ok, postcommit_checks} <-
           Verification.run(
             context.repository,
             context.work_order["id"],
             context.worktree,
             Verification.commands(context.spec.profile, context.spec.checks),
             round: repair_attempt + 101
           ) do
      if postcommit_checks.passed do
        prepare_review(
          context,
          candidate,
          precommit_checks,
          postcommit_checks,
          repair_attempt
        )
      else
        with :ok <- Git.undo_candidate(context.worktree, context.baseline) do
          repair_or_stop(context, repair_attempt, postcommit_checks)
        else
          {:error, error} -> stop(context, error)
        end
      end
    else
      {:error, error} -> stop(context, error)
    end
  end

  defp repair_or_stop(context, repair_attempt, failure) do
    if repair_attempt < context.max_repairs do
      run_repair(context, repair_attempt, failure)
    else
      stop(
        context,
        error(
          :repair_limit_reached,
          "Verification failed after the configured repair limit.",
          %{failure: failure}
        )
      )
    end
  end

  defp run_repair(context, repair_attempt, failure) do
    with {:ok, next} <-
           transition(
             context.repository,
             context.work_order,
             context.definition,
             "checks_failed",
             "Required verification failed"
           ) do
      repairing = %{context | work_order: next.work_order}

      case Executor.run_station(
             repairing.repository,
             repairing.config,
             repairing.definition,
             repairing.work_order,
             "repair",
             repair_prompt(repairing, failure, repair_attempt + 1),
             worktree_path: repairing.worktree,
             attempt: repair_attempt + 1,
             model: Keyword.get(repairing.options, :model)
           ) do
        {:ok, %{result: %{status: "success"}}} ->
          with :ok <- Git.assert_head(repairing.worktree, repairing.baseline),
               {:ok, paths} <- Git.changed_paths(repairing.worktree),
               :ok <- Git.verify_scope(paths, repairing.spec.allowed_scopes),
               {:ok, verified} <-
                 transition(
                   repairing.repository,
                   repairing.work_order,
                   repairing.definition,
                   "repair_ready",
                   "Repair is ready for checks"
                 ) do
            verify(%{repairing | work_order: verified.work_order}, repair_attempt + 1)
          else
            {:error, error} -> stop(repairing, error)
          end

        {:ok, execution} ->
          stop(
            repairing,
            error(:repair_failed, "Repair harness ended with '#{execution.result.status}'.")
          )

        {:error, error} ->
          stop(repairing, error)
      end
    else
      {:error, error} -> stop(context, error)
    end
  end

  defp prepare_review(
         context,
         candidate,
         precommit_checks,
         postcommit_checks,
         repair_attempt
       ) do
    with :ok <- Git.assert_target_unchanged(context.repository, context.baseline),
         {:ok, changed_paths} <-
           Git.changed_paths_between(context.worktree, context.baseline, candidate),
         {:ok, receipt_artifact} <-
           write_receipt(
             context,
             candidate,
             changed_paths,
             precommit_checks,
             postcommit_checks
           ),
         {:ok, next} <-
           Journal.transition(
             context.repository,
             context.work_order["id"],
             context.definition,
             %Event{
               name: "checks_passed",
               expected_state: "verifying",
               actor: "hancho",
               reason: "Candidate checks passed"
             },
             %{artifacts: ["check_result"]}
           ) do
      review(
        %{context | work_order: next.work_order},
        candidate,
        receipt_artifact,
        precommit_checks,
        postcommit_checks,
        repair_attempt
      )
    else
      {:error, error} -> stop(context, error)
    end
  end

  defp review(
         context,
         candidate,
         receipt_artifact,
         precommit_checks,
         postcommit_checks,
         repair_attempt
       ) do
    with :ok <- independent_review_route(context) do
      case Executor.run_station(
             context.repository,
             context.config,
             context.definition,
             context.work_order,
             "review",
             review_prompt(context, candidate, precommit_checks, postcommit_checks),
             worktree_path: context.worktree,
             attempt: repair_attempt + 1,
             model: Keyword.get(context.options, :model)
           ) do
        {:ok, %{result: %{status: "success"}} = review} ->
          accept_review(context, candidate, receipt_artifact, review)

        {:ok, execution} ->
          review_rework_or_stop(context, candidate, execution, repair_attempt)

        {:error, error} ->
          review_rework_or_stop(context, candidate, %{error: error}, repair_attempt)
      end
    else
      {:error, error} -> stop(context, error)
    end
  end

  defp independent_review_route(context) do
    if get_in(context.config.data, ["review", "require_independent_harness"]) == true do
      with {:ok, review_route} <- Router.resolve(context.config, context.definition, "review") do
        if review_route.name == context.implementation.resolved.name do
          {:error,
           error(
             :independent_reviewer_required,
             "Policy requires a review harness different from the implementation harness."
           )}
        else
          :ok
        end
      end
    else
      :ok
    end
  end

  defp accept_review(context, candidate, receipt_artifact, review) do
    with :ok <- Git.assert_head(context.worktree, candidate),
         {:ok, []} <- Git.changed_paths(context.worktree),
         :ok <- Git.assert_target_unchanged(context.repository, context.baseline),
         :ok <- Git.retain_candidate(context.repository, context.work_order["id"], candidate) do
      if "candidate_acceptance" in context.spec.required_gates do
        await_candidate_acceptance(context, candidate, receipt_artifact, review)
      else
        finalize_candidate(context, candidate, receipt_artifact, review)
      end
    else
      {:ok, paths} ->
        stop(
          context,
          error(
            :review_changed_candidate,
            "Review changed the worktree: #{Enum.join(paths, ", ")}."
          )
        )

      {:error, error} ->
        stop(context, error)
    end
  end

  defp await_candidate_acceptance(context, candidate, receipt_artifact, review) do
    with {:ok, waiting} <-
           Journal.transition(
             context.repository,
             context.work_order["id"],
             context.definition,
             %Event{
               name: "review_recommended",
               expected_state: "reviewing",
               actor: "reviewer",
               reason: "Harness review recommends the exact candidate for human acceptance"
             },
             %{artifacts: ["candidate_receipt"]}
           ),
         {:ok, decision} <-
           Journal.request_decision(
             context.repository,
             context.work_order["id"],
             "candidate_acceptance",
             %{
               candidate_commit: candidate,
               receipt_hash: receipt_artifact["content_hash"],
               work_ref: context.work_order["work_ref"]
             }
           ) do
      {:ok,
       %{
         work_order: waiting.work_order,
         candidate_commit: candidate,
         receipt: receipt_artifact,
         review: review,
         implementation: context.implementation,
         decision: decision
       }}
    end
  end

  defp finalize_candidate(context, candidate, receipt_artifact, review) do
    with {:ok, final} <-
           Journal.transition(
             context.repository,
             context.work_order["id"],
             context.definition,
             %Event{
               name: "review_accepted",
               expected_state: "reviewing",
               actor: "reviewer",
               reason: "Review accepted the exact candidate"
             },
             %{artifacts: ["candidate_receipt"]}
           ),
         :ok <- Git.remove_worktree(context.repository, context.worktree) do
      {:ok,
       %{
         work_order: final.work_order,
         candidate_commit: candidate,
         receipt: receipt_artifact,
         review: review,
         implementation: context.implementation
       }}
    end
  end

  defp review_rework_or_stop(context, candidate, finding, repair_attempt) do
    if repair_attempt < context.max_repairs do
      with {:ok, next} <-
             transition(
               context.repository,
               context.work_order,
               context.definition,
               "review_rework",
               "Review requested rework"
             ),
           :ok <- Git.undo_candidate(context.worktree, context.baseline) do
        run_review_repair(%{context | work_order: next.work_order}, finding, repair_attempt)
      else
        {:error, error} -> stop(context, error)
      end
    else
      stop(
        context,
        error(
          :review_rework_limit,
          "Review requested rework after the configured limit.",
          %{candidate: candidate, finding: inspect(finding)}
        )
      )
    end
  end

  defp run_review_repair(context, finding, repair_attempt) do
    case Executor.run_station(
           context.repository,
           context.config,
           context.definition,
           context.work_order,
           "repair",
           repair_prompt(context, finding, repair_attempt + 1),
           worktree_path: context.worktree,
           attempt: repair_attempt + 1
         ) do
      {:ok, %{result: %{status: "success"}}} ->
        with :ok <- Git.assert_head(context.worktree, context.baseline),
             {:ok, next} <-
               transition(
                 context.repository,
                 context.work_order,
                 context.definition,
                 "repair_ready",
                 "Review rework is ready for checks"
               ) do
          verify(%{context | work_order: next.work_order}, repair_attempt + 1)
        else
          {:error, error} -> stop(context, error)
        end

      _ ->
        stop(context, error(:review_repair_failed, "Review rework did not complete."))
    end
  end

  defp gates(context, paths) do
    required =
      Gates.required(paths, context.spec.required_gates)
      |> Enum.reject(&(&1 == "candidate_acceptance"))

    with {:ok, fingerprint} <- Git.worktree_fingerprint(context.worktree) do
      approved = approved_gate_names(context.approval_records, fingerprint)
      missing = Gates.missing(required, approved)

      if missing == [] do
        :ok
      else
        Enum.each(missing, fn gate ->
          Journal.request_decision(context.repository, context.work_order["id"], gate, %{
            gate: gate,
            paths: paths,
            baseline_commit: context.baseline,
            worktree_fingerprint: fingerprint,
            work_ref: context.work_order["work_ref"]
          })
        end)

        {:error,
         error(
           :gate_required,
           "Required approvals are missing or stale: #{Enum.join(missing, ", ")}.",
           %{gates: missing, worktree_fingerprint: fingerprint}
         )}
      end
    end
  end

  defp approved_gate_names(records, fingerprint) do
    records
    |> Enum.filter(fn decision ->
      request = JSON.decode!(decision["request_json"] || "{}")
      decision["status"] == "approved" and request["worktree_fingerprint"] == fingerprint
    end)
    |> Enum.map(& &1["kind"])
  end

  defp stop(context, %Error{} = error) do
    with {:ok, current} <-
           Journal.get_work_order(context.repository, context.work_order["id"]),
         {:ok, stopped} <-
           Journal.transition(
             context.repository,
             current["id"],
             context.definition,
             %Event{
               name: "andon",
               expected_state: current["state"],
               actor: "hancho",
               reason: error.message,
               payload: %{error_code: error.code}
             }
           ) do
      {:ok, %{work_order: stopped.work_order, error: error, worktree: context.worktree}}
    else
      {:error, _stop_error} -> {:error, error}
    end
  end

  defp write_receipt(
         context,
         candidate,
         changed_paths,
         precommit_checks,
         postcommit_checks
       ) do
    receipt = %{
      schema_version: 1,
      work_order_id: context.work_order["id"],
      work_ref: context.work_order["work_ref"],
      workflow: %{name: context.definition.name, version: context.definition.version},
      baseline_commit: context.baseline,
      candidate_commit: candidate,
      target_branch: context.branch,
      changed_paths: changed_paths,
      allowed_scopes: context.spec.allowed_scopes,
      precommit_checks: precommit_checks,
      postcommit_checks: postcommit_checks,
      implementation_harness: harness_identity(context.implementation),
      config_hash: context.config.hash,
      approvals: context.approvals
    }

    Artifacts.write(
      context.repository,
      context.work_order["id"],
      "receipt",
      "candidate.json",
      JSON.encode!(receipt),
      media_type: "application/json",
      retention: "durable"
    )
  end

  defp implementation_prompt(context) do
    """
    Implement exactly one admitted Hancho Build.V1 work order.

    Work order: #{context.work_order["id"]}
    Work reference: #{context.work_order["work_ref"]}
    Title: #{context.spec.title}
    Baseline: #{context.baseline}

    Instructions:
    #{context.spec.instructions}

    Allowed scope:
    #{Enum.map_join(context.spec.allowed_scopes, "\n", &"- #{&1}")}

    Acceptance conditions:
    #{Enum.map_join(context.spec.acceptance_conditions, "\n", &"- #{&1}")}

    Do not commit, push, merge, release, deploy, or change work records. Hancho owns those effects.
    """
  end

  defp repair_prompt(context, failure, attempt) do
    """
    Repair Build.V1 attempt #{attempt}. Change only the admitted scope.
    Do not commit, push, merge, release, deploy, or change work records.

    Failure evidence:
    #{JSON.encode!(failure)}

    Allowed scope:
    #{Enum.map_join(context.spec.allowed_scopes, "\n", &"- #{&1}")}
    """
  end

  defp review_prompt(context, candidate, precommit_checks, postcommit_checks) do
    {:ok, diff} =
      Git.command(context.worktree, [
        "diff",
        "--stat",
        "#{context.baseline}..#{candidate}"
      ])

    """
    Review the exact Build.V1 candidate. Do not change files or Git state.

    Candidate: #{candidate}
    Baseline: #{context.baseline}
    Work reference: #{context.work_order["work_ref"]}
    Acceptance conditions: #{JSON.encode!(context.spec.acceptance_conditions)}
    Precommit checks: #{JSON.encode!(precommit_checks)}
    Postcommit checks: #{JSON.encode!(postcommit_checks)}

    Diff summary:
    #{diff}
    """
  end

  defp transition(repository, work_order, definition, event, reason) do
    Journal.transition(
      repository,
      work_order["id"],
      definition,
      %Event{
        name: event,
        expected_state: work_order["state"],
        actor: "hancho",
        reason: reason
      }
    )
  end

  defp harness_identity(nil), do: nil

  defp harness_identity(implementation) do
    %{
      adapter: implementation.result.adapter,
      harness: implementation.result.harness,
      adapter_version: implementation.result.adapter_version,
      harness_version: implementation.result.harness_version,
      session_id: implementation.result.session_id
    }
  end

  defp actor, do: System.get_env("USER") || "local-user"

  defp store_work_references(repository, run_id, spec) do
    if spec.github_issue || spec.beadwork do
      Hancho.WorkRecords.link(repository, run_id,
        github_issue: spec.github_issue,
        beadwork: spec.beadwork,
        metadata: %{acceptance_conditions: spec.acceptance_conditions}
      )
    else
      :ok
    end
  end

  defp resumable_gate_stop(repository, work_order) do
    with true <- work_order["workflow_name"] == "build" and work_order["state"] == "stopped",
         true <- is_binary(work_order["worktree_path"]) and File.dir?(work_order["worktree_path"]),
         {:ok, events} <- Journal.events(repository, work_order["id"]),
         last when is_map(last) <- Enum.find(Enum.reverse(events), &(&1["event"] == "andon")),
         payload <- JSON.decode!(last["payload_json"] || "{}"),
         "gate_required" <- get_in(payload, ["payload", "error_code"]) do
      :ok
    else
      _ ->
        {:error,
         %Error{
           code: :resume_not_permitted,
           exit_status: 75,
           message: "Build work order '#{work_order["id"]}' is not a safe approved-gate resume."
         }}
    end
  end

  defp load_stored_spec(repository, work_order) do
    with {:ok, artifacts} <- Artifacts.list(repository, work_order["id"]),
         artifact when is_map(artifact) <- Enum.find(artifacts, &(&1["kind"] == "work_spec")),
         path <- Path.join(repository.runtime_dir, artifact["relative_path"]),
         data <- JSON.decode!(File.read!(path)),
         {:ok, spec} <- WorkSpec.load(work_order["work_ref"], work_spec: data) do
      {:ok, spec}
    else
      _ ->
        {:error,
         %Error{
           code: :stored_work_spec_missing,
           exit_status: 74,
           message: "Stored work specification is missing or invalid."
         }}
    end
  end

  defp approved_decisions(repository, run_id) do
    case Hancho.SQLite.query(
           Hancho.Store.path(repository),
           "SELECT * FROM decisions WHERE run_id = #{Hancho.SQLite.quote(run_id)} AND status = 'approved' ORDER BY decided_at, id;"
         ) do
      {:ok, decisions} -> {:ok, decisions}
      {:error, error} -> {:error, error}
    end
  end

  defp error(code, message, details \\ nil),
    do: %Error{code: code, exit_status: 75, message: message, details: details}
end
