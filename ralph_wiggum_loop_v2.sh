#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./ralph_wiggum_loop_v2.sh [options]

Runs the LLMux beadwork ticket queue with one fresh grok session and one
isolated Git worktree for each ticket.

This is the v2 runner. It does not read llmux_plan/execution or queue.tsv.
Tickets come from beadwork (`bw list` / `bw ready` semantics). The agent is
the `grok` CLI, not zclaude.

Selection:
  --start-at ID            Start at this ticket or execution-card ID, inclusive
  --end-at ID              End at this ticket or execution-card ID, inclusive
  --only ID                Select only one ticket or execution-card ID
  --max N                  Process at most N selected tickets
  --include-blocked        Do not skip tickets that still have open blockers
  --dry-run                Print the selected tickets and exit

  Default queue: open or in-progress tasks whose beadwork blockers are closed.
  Closed tickets are skipped unless --only names them.

Harness:
  --model MODEL            Pass a model name to grok (default: grok-4.6)
  --permission-mode MODE   grok permission mode (default: acceptEdits)
  --grok-arg ARG           Extra grok argument; repeat as needed
  --max-fix-attempts N     Maximum repair runs after failed verification (default: 2)

Beadwork:
  --no-claim               Do not run `bw start` before a ticket
  --no-close               Do not close or sync the ticket after acceptance

Git:
  --push                   Push each accepted commit; off by default
  --remote NAME            Push remote (default: origin)
  --branch NAME            Push branch; must be the checked-out branch

Environment:
  LOG_FILE                 Main log (default: .git/llmux-execution/ralph-v2.log)
  RALPH_MIX_CACHE          Set to 0 to disable shared deps and build caches
  RALPH_GROK_MODEL         Default model when --model is not supplied (default: grok-4.6)
  GATE_REVIEWER            Name stored with command-line gate approvals

Examples:
  ./ralph_wiggum_loop_v2.sh --dry-run --max 5
  ./ralph_wiggum_loop_v2.sh --only EX-M01-E01-T10-01
  ./ralph_wiggum_loop_v2.sh --only llmux-ex-m01-e01-t10-01
  ./ralph_wiggum_loop_v2.sh --start-at EX-M01-E01-T10-01 --max 3 \
    --permission-mode bypassPermissions
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*" >&2
  if [ -n "${ACTIVE_WORKTREE:-}" ]; then
    log "Failed worktree retained at: $ACTIVE_WORKTREE" >&2
  fi
  exit 1
}

handle_interrupt() {
  log "Interrupted. The active worktree is retained for inspection." >&2
  exit 130
}

trap handle_interrupt INT TERM

require_value() {
  local option="$1"
  local count="$2"
  if [ "$count" -lt 2 ] || [ -z "${3:-}" ] || [[ "${3:-}" == -* ]]; then
    fail "Option ${option} requires a non-flag value"
  fi
}

is_non_negative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

absolute_dir() {
  (cd "$1" 2>/dev/null && pwd)
}

assert_clean_main_tree() {
  local status
  status="$(git -C "$REPO_ROOT" status --porcelain)"
  [ -z "$status" ] || fail "The main worktree is not clean. Commit the runner and all other changes first."
}

ticket_record() {
  local needle="$1"
  jq -c --arg needle "$needle" '
    [.[] | select(.id == $needle or .card_id == $needle)] | .[0] // empty
  ' "$TICKETS_JSON"
}

ticket_field() {
  local needle="$1"
  local field="$2"
  local record
  record="$(ticket_record "$needle")"
  [ -n "$record" ] || return 1
  jq -r --arg field "$field" '.[$field] | if . == null then empty elif type == "array" then join(",") else tostring end' <<< "$record"
}

ticket_id_for() {
  ticket_field "$1" "id"
}

card_id_for() {
  ticket_field "$1" "card_id"
}

write_ticket_body() {
  local needle="$1"
  local dest="$2"
  local record
  record="$(ticket_record "$needle")"
  [ -n "$record" ] || fail "Beadwork ticket not loaded: $needle"
  jq -r '"# " + .card_id + ": " + .title + "\n\n" + .description + "\n"' <<< "$record" > "$dest"
}

mark_ticket_status() {
  local ticket_id="$1"
  local status="$2"
  local tmp
  tmp="${TICKETS_JSON}.tmp"
  jq --arg id "$ticket_id" --arg status "$status" '
    map(if .id == $id then .status = $status else . end)
  ' "$TICKETS_JSON" > "$tmp"
  mv "$tmp" "$TICKETS_JSON"
}

card_commit_list() {
  local card_id="$1"
  local ticket_id="${2:-}"
  local pattern

  if [ -n "$ticket_id" ] && [ "$ticket_id" != "$card_id" ]; then
    pattern="^(Execution-Card: ${card_id}|Beadwork-Issue: ${ticket_id})$"
  else
    pattern="^(Execution-Card: ${card_id}|Beadwork-Issue: ${card_id})$"
  fi

  git -C "$REPO_ROOT" log "$TARGET_BRANCH" --format='%H' \
    --extended-regexp --grep="$pattern"
}

accepted_commit_for() {
  local card_id="$1"
  local ticket_id="${2:-}"
  local commits=()
  local commit
  local receipt
  local source_task
  local body_file
  local current_hash
  local message

  if [ -z "$ticket_id" ]; then
    ticket_id="$(ticket_id_for "$card_id" || true)"
  fi

  while IFS= read -r commit; do
    [ -z "$commit" ] || commits+=("$commit")
  done < <(card_commit_list "$card_id" "$ticket_id")

  [ "${#commits[@]}" -eq 1 ] || return 1
  commit="${commits[0]}"
  receipt="${RECEIPTS_ROOT}/${card_id}/${commit}.json"
  [ -f "$receipt" ] || return 1
  grep -Eq '"accepted"[[:space:]]*:[[:space:]]*true' "$receipt" || return 1

  source_task="$(ticket_field "$card_id" "source_task" || true)"
  body_file="$(mktemp "${TMPDIR:-/tmp}/llmux-ticket-body.XXXXXX")"
  write_ticket_body "$card_id" "$body_file"
  current_hash="$(card_hash "$body_file")"
  rm -f "$body_file"
  grep -Fq "\"card_sha256\": \"${current_hash}\"" "$receipt" || return 1
  message="$(git -C "$REPO_ROOT" show -s --format='%B' "$commit")"
  if [ -n "$source_task" ]; then
    grep -Fxq "Source-Roadmap-Task: $source_task" <<< "$message" || return 1
  fi
  grep -Fxq "Execution-Card-Hash: $current_hash" <<< "$message" || return 1
  if [ -n "$ticket_id" ]; then
    grep -Fxq "Beadwork-Issue: $ticket_id" <<< "$message" || return 1
  fi
  printf '%s\n' "$commit"
}

card_state() {
  local card_id="$1"
  local ticket_id="${2:-}"
  local commits=()
  local commit
  local status

  if [ -z "$ticket_id" ]; then
    ticket_id="$(ticket_id_for "$card_id" || true)"
  fi
  if [ -n "$ticket_id" ]; then
    status="$(ticket_field "$ticket_id" "status" || true)"
    if [ "$status" = "closed" ]; then
      printf 'complete'
      return 0
    fi
    if ticket_is_blocked "$ticket_id"; then
      printf 'blocked'
      return 0
    fi
  fi

  while IFS= read -r commit; do
    [ -z "$commit" ] || commits+=("$commit")
  done < <(card_commit_list "$card_id" "$ticket_id")

  if [ "${#commits[@]}" -gt 1 ]; then
    printf 'invalid-multiple-commits'
  elif [ "${#commits[@]}" -eq 1 ]; then
    if accepted_commit_for "$card_id" "$ticket_id" >/dev/null; then
      printf 'complete'
    else
      printf 'commit-without-accepted-receipt'
    fi
  else
    printf 'pending'
  fi
}

section_items() {
  local card_file="$1"
  local section="$2"
  awk -v section="$section" '
    function norm(s) {
      sub(/\r$/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      line = norm($0)
      if (line == "## " section || line == "### " section || line == "#### " section) {
        inside = 1
        next
      }
      if (inside && line ~ /^#{2,} /) {
        exit
      }
      if (inside && $0 ~ /^- /) {
        sub(/^- /, "")
        print
      }
    }
  ' "$card_file"
}

strip_backticks() {
  local value="$1"
  value="${value#\`}"
  value="${value%\`}"
  printf '%s\n' "$value"
}

card_title() {
  local card_id="$1"
  local card_file="$2"
  local title
  title="$(sed -n "1s/^# ${card_id}: //p" "$card_file")"
  if [ -n "$title" ]; then
    printf '%s\n' "$title"
    return 0
  fi
  title="$(ticket_field "$card_id" "title" || true)"
  title="${title#"${card_id}: "}"
  printf '%s\n' "$title"
}

card_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
}

approval_present() {
  local requested="$1"
  local approval
  for approval in "${GATE_APPROVALS[@]-}"; do
    [ "$approval" = "$requested" ] && return 0
  done
  return 1
}

validate_approval_format() {
  local approval="$1"
  [[ "$approval" =~ ^(EX-M[0-9]{2}-E[0-9]{2}-T[0-9]{2}-[0-9]{2}|llmux-[A-Za-z0-9-]+):GATE_[A-Z0-9_]+$ ]] ||
    fail "Invalid gate approval: $approval"
}

path_allowed() {
  local path="$1"
  local scope
  for scope in "${ALLOWED_SCOPES[@]}"; do
    if [[ "$scope" == */ ]]; then
      [[ "$path" == "$scope"* ]] && return 0
    elif [ "$path" = "$scope" ]; then
      return 0
    fi
  done
  return 1
}

append_changed_path() {
  local candidate="$1"
  local existing
  [ -n "$candidate" ] || return 0
  for existing in "${CHANGED_PATHS[@]-}"; do
    [ "$existing" = "$candidate" ] && return 0
  done
  CHANGED_PATHS+=("$candidate")
}

collect_changed_paths() {
  local entry
  local status
  local path
  local source_path
  CHANGED_PATHS=()

  while IFS= read -r -d '' entry; do
    status="${entry:0:2}"
    path="${entry:3}"
    append_changed_path "$path"
    if [[ "$status" == *R* || "$status" == *C* ]]; then
      IFS= read -r -d '' source_path || true
      append_changed_path "$source_path"
    fi
  done < <(git -C "$ACTIVE_WORKTREE" status --porcelain=v1 -z --untracked-files=all)
}

load_allowed_scopes() {
  local card_file="$1"
  local item
  ALLOWED_SCOPES=()
  while IFS= read -r item; do
    [ -z "$item" ] || ALLOWED_SCOPES+=("$(strip_backticks "$item")")
  done < <(section_items "$card_file" "Allowed Scope")
  [ "${#ALLOWED_SCOPES[@]}" -gt 0 ] || fail "Ticket has no allowed scope: $card_file"
}

verify_changed_scope() {
  local path
  collect_changed_paths
  [ "${#CHANGED_PATHS[@]}" -gt 0 ] || return 1
  for path in "${CHANGED_PATHS[@]}"; do
    path_allowed "$path" || fail "Ticket changed a path outside Allowed Scope: $path"
  done
}

restore_out_of_scope_paths() {
  local path
  local restored=0
  collect_changed_paths
  for path in "${CHANGED_PATHS[@]-}"; do
    path_allowed "$path" && continue
    log "WARNING: discarding out-of-scope change: $path"
    if git -C "$ACTIVE_WORKTREE" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      git -C "$ACTIVE_WORKTREE" checkout -- "$path"
    else
      rm -rf "${ACTIVE_WORKTREE}/${path}"
    fi
    restored=1
  done
  if [ "$restored" -eq 1 ]; then
    log "Out-of-scope changes were discarded so the ticket stays inside Allowed Scope"
  fi
}

enforce_detectable_gates() {
  local card_id="$1"
  local ticket_id="$2"
  local path
  for path in "${CHANGED_PATHS[@]}"; do
    if { [ "$path" = "mix.exs" ] || [ "$path" = "mix.lock" ]; } &&
      ! approval_present "${card_id}:GATE_NEW_DEP" &&
      ! approval_present "${ticket_id}:GATE_NEW_DEP"; then
      fail "Changes to $path require --approve-gate ${card_id}:GATE_NEW_DEP"
    fi
    if { [[ "$path" == priv/repo/migrations/* ]] || [[ "$path" == priv/resource_snapshots/* ]]; } &&
      ! approval_present "${card_id}:GATE_MIGRATION" &&
      ! approval_present "${ticket_id}:GATE_MIGRATION"; then
      fail "Changes to $path require --approve-gate ${card_id}:GATE_MIGRATION"
    fi
  done
}

enforce_pre_run_gates() {
  local card_id="$1"
  local ticket_id="$2"
  local card_file="$3"
  if section_items "$card_file" "Human Gates" |
      rg -q 'GATE_M04_PROMOTION' ||
    section_items "$card_file" "Human Review or Stop Conditions" |
      rg -q '^GATE_M04_PROMOTION:'; then
    approval_present "${card_id}:GATE_M04_PROMOTION" ||
      approval_present "${ticket_id}:GATE_M04_PROMOTION" ||
      fail "$card_id requires --approve-gate ${card_id}:GATE_M04_PROMOTION"
  fi
}

build_grok_command() {
  GROK_CMD=(
    grok
    --output-format streaming-json
    --verbatim
    --no-memory
    --no-plan
    --permission-mode "$GROK_PERMISSION_MODE"
    --deny 'Bash(git commit*)'
    --deny 'Bash(git push*)'
  )
  if [ "$GROK_PERMISSION_MODE" = "bypassPermissions" ]; then
    GROK_CMD+=(--always-approve)
  fi
  if [ -n "$GROK_MODEL" ]; then
    GROK_CMD+=(--model "$GROK_MODEL")
  fi
  if [ "${#GROK_EXTRA_ARGS[@]}" -gt 0 ]; then
    GROK_CMD+=("${GROK_EXTRA_ARGS[@]}")
  fi
}

render_grok_stream() {
  jq --unbuffered -Rr '
    def clipped($limit):
      tostring as $text
      | if ($text | length) > $limit
        then ($text[0:$limit] + "…")
        else $text
        end;

    fromjson?
    | if .type == "text" and ((.data // "") != "") then
        "[assistant] " + .data
      elif .type == "thought" and ((.data // "") != "") then
        "[thinking] " + (.data | clipped(500))
      elif .type == "tool_call" then
        "[tool] " + ((.toolName // .title // "unknown") | tostring)
        + " " + ((.rawInput // {}) | tojson | clipped(500))
      elif .type == "tool_call_update" then
        "[tool result] " + ((.status // "update") | tostring)
      elif .type == "end" then
        "[grok] result=" + ((.stopReason // "unknown") | tostring)
        + "; turns=" + ((.num_turns // 0) | tostring)
      elif .type == "error" then
        "[grok] error=" + ((.message // "unknown") | tostring)
      else
        empty
      end
  '
}

run_grok() {
  local prompt_file="$1"
  local output_file="$2"
  local session_id
  local exit_code
  local renderer_exit
  local pipeline_status=()

  session_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  log "Running grok in $ACTIVE_WORKTREE (session $session_id)"
  set +e
  (
    cd "$ACTIVE_WORKTREE"
    "${GROK_CMD[@]}" \
      --session-id "$session_id" \
      --cwd "$ACTIVE_WORKTREE" \
      --prompt-file "$prompt_file"
  ) 2> >(tee "${output_file}.stderr" >&2) \
    | tee "$output_file" \
    | render_grok_stream \
    | tee "${output_file}.events"
  pipeline_status=("${PIPESTATUS[@]}")
  exit_code=${pipeline_status[0]}
  renderer_exit=${pipeline_status[2]}
  set -e
  if [ "$renderer_exit" -ne 0 ]; then
    log "The grok stream renderer failed; raw events are in $output_file" >&2
    return "$renderer_exit"
  fi
  return "$exit_code"
}

make_implementation_prompt() {
  local card_id="$1"
  local ticket_id="$2"
  local source_task="$3"
  local card_file="$4"
  local prompt_file="$5"
  local approval
  local approved=0

  {
    printf '%s\n' "Implement exactly one LLMux beadwork ticket."
    printf '\nTicket ID: %s\n' "$ticket_id"
    printf 'Execution card ID: %s\n' "$card_id"
    if [ -n "$source_task" ]; then
      printf 'Source roadmap task: %s\n' "$source_task"
    fi
    printf 'Ticket SHA-256: %s\n\n' "$CURRENT_CARD_HASH"
    printf '%s\n' "Beadwork ticket:"
    printf '%s\n' '```markdown'
    cat "$card_file"
    printf '%s\n\n' '```'
    printf '%s\n' "Rules:"
    printf '%s\n' "- Follow AGENTS.md and repository conventions."
    printf '%s\n' "- Work only inside the ticket Allowed Scope."
    printf '%s\n' "- Implement only this ticket and its acceptance criteria."
    printf '%s\n' "- Do not commit, push, open a PR, or edit planning files."
    printf '%s\n' "- Do not run bw start, bw close, or bw sync; the runner owns beadwork status."
    printf '%s\n' "- Do not change a gated decision unless it is approved below."
    printf '%s\n' "- If an unapproved gate is necessary, make no gated change and report the gate."
    printf '%s\n' "- Run focused checks while you work. The runner will repeat all required checks."
    printf '%s\n\n' "Gate approvals for this run:"
    for approval in "${GATE_APPROVALS[@]-}"; do
      if [[ "$approval" == "${card_id}:"* || "$approval" == "${ticket_id}:"* ]]; then
        printf -- '- %s\n' "${approval#*:}"
        approved=1
      fi
    done
    [ "$approved" -eq 1 ] || printf '%s\n' "- None"
    printf '\n%s\n' "Final response: changed files, checks run, acceptance coverage, and blockers."
  } > "$prompt_file"
}

make_repair_prompt() {
  local card_id="$1"
  local prompt_file="$2"
  local failure_log="$3"
  {
    printf 'Repair verification failures for beadwork ticket %s.\n\n' "$card_id"
    printf '%s\n' "Follow AGENTS.md and the original ticket scope. Do not add scope, commit, or push."
    printf '%s\n' "Do not run bw start, bw close, or bw sync."
    printf '%s\n' "Fix only the failures below. Leave the worktree ready for all checks."
    printf '%s\n' "Never edit a file outside Allowed Scope, including an unrelated failing test."
    printf '%s\n' "If a failure is outside Allowed Scope, report it and leave those files unchanged."
    printf '%s\n' '```text'
    tail -n 300 "$failure_log"
    printf '%s\n' '```'
  } > "$prompt_file"
}

stage_and_commit() {
  local card_id="$1"
  local ticket_id="$2"
  local source_task="$3"
  local title="$4"
  local amend="$5"
  local path

  verify_changed_scope || fail "No changes found for $card_id"
  enforce_detectable_gates "$card_id" "$ticket_id"

  # Stage tracked modifications and deletions before new files. A repair can
  # delete a tracked artifact and add an ignore rule for it. In that state,
  # `git add -A -- deleted-path` rejects the now-ignored path.
  git -C "$ACTIVE_WORKTREE" add -u -- .
  for path in "${CHANGED_PATHS[@]}"; do
    if [ -e "${ACTIVE_WORKTREE}/${path}" ] || [ -L "${ACTIVE_WORKTREE}/${path}" ]; then
      git -C "$ACTIVE_WORKTREE" add -- "$path"
    fi
  done
  git -C "$ACTIVE_WORKTREE" diff --cached --check

  if [ "$amend" -eq 1 ]; then
    git -C "$ACTIVE_WORKTREE" commit --amend --no-edit
  else
    if [ -n "$source_task" ]; then
      git -C "$ACTIVE_WORKTREE" commit \
        -m "feat(card): ${card_id} ${title}" \
        -m "Execution-Card: ${card_id}" \
        -m "Beadwork-Issue: ${ticket_id}" \
        -m "Source-Roadmap-Task: ${source_task}" \
        -m "Execution-Card-Hash: ${CURRENT_CARD_HASH}"
    else
      git -C "$ACTIVE_WORKTREE" commit \
        -m "feat(card): ${card_id} ${title}" \
        -m "Execution-Card: ${card_id}" \
        -m "Beadwork-Issue: ${ticket_id}" \
        -m "Execution-Card-Hash: ${CURRENT_CARD_HASH}"
    fi
  fi
}

load_verification_commands() {
  local card_file="$1"
  local item
  FOCUSED_COMMANDS=()
  FULL_COMMANDS=()

  while IFS= read -r item; do
    [ -z "$item" ] || FOCUSED_COMMANDS+=("$(strip_backticks "$item")")
  done < <(section_items "$card_file" "Focused Verification")

  if [ "${#FOCUSED_COMMANDS[@]}" -eq 0 ]; then
    while IFS= read -r item; do
      [ -z "$item" ] || FOCUSED_COMMANDS+=("$(strip_backticks "$item")")
    done < <(section_items "$card_file" "Focused Verification Commands")
  fi

  while IFS= read -r item; do
    [ -z "$item" ] || FULL_COMMANDS+=("$(strip_backticks "$item")")
  done < <(section_items "$card_file" "Full Verification Gate")

  if [ "${#FULL_COMMANDS[@]}" -eq 0 ]; then
    FULL_COMMANDS+=("mix precommit")
  fi

  [ "${#FOCUSED_COMMANDS[@]}" -gt 0 ] || fail "Ticket has no focused verification command"
  [ "${#FULL_COMMANDS[@]}" -gt 0 ] || fail "Ticket has no full verification gate"
}

run_one_check() {
  local phase="$1"
  local index="$2"
  local command="$3"
  local output_file
  local exit_code

  if [[ "$command" == "Not applicable:"* ]]; then
    return 0
  fi

  output_file="${ACTIVE_RUN_DIR}/round-${CHECK_ROUND}-${phase}-${index}.log"
  log "Running ${phase} check: $command"
  set +e
  (
    cd "$ACTIVE_WORKTREE"
    /bin/bash -lc "$command"
  ) > "$output_file" 2>&1
  exit_code=$?
  set -e

  CHECK_COMMANDS+=("$command")
  CHECK_EXIT_CODES+=("$exit_code")
  CHECK_OUTPUTS+=("$output_file")

  if [ "$exit_code" -ne 0 ]; then
    tail -n 120 "$output_file" >&2
    FAILED_CHECK_LOG="$output_file"
    return 1
  fi
  return 0
}

run_all_checks() {
  local require_clean="$1"
  local card_id="$2"
  local ticket_id="$3"
  local command
  local index=0
  CHECK_ROUND=$((CHECK_ROUND + 1))
  CHECK_COMMANDS=()
  CHECK_EXIT_CODES=()
  CHECK_OUTPUTS=()
  FAILED_CHECK_LOG=""

  for command in "${FOCUSED_COMMANDS[@]}"; do
    index=$((index + 1))
    run_one_check focused "$index" "$command" || return 1
  done

  index=0
  for command in "${FULL_COMMANDS[@]}"; do
    index=$((index + 1))
    run_one_check full "$index" "$command" || return 1
  done

  if [ "$require_clean" -eq 1 ] && [ -n "$(git -C "$ACTIVE_WORKTREE" status --porcelain)" ]; then
    FAILED_CHECK_LOG="${ACTIVE_RUN_DIR}/round-${CHECK_ROUND}-verification-dirty-worktree.log"
    git -C "$ACTIVE_WORKTREE" status --short > "$FAILED_CHECK_LOG"
    log "Verification changed the worktree" >&2
    return 1
  fi
  if [ "$require_clean" -eq 0 ]; then
    verify_changed_scope || fail "No changes remain after verification for $card_id"
    enforce_detectable_gates "$card_id" "$ticket_id"
    git -C "$ACTIVE_WORKTREE" diff --check
  fi
  return 0
}

run_repair() {
  local card_id="$1"
  local repair_prompt

  if [ "$REPAIR_ATTEMPT" -ge "$MAX_FIX_ATTEMPTS" ]; then
    fail "Verification failed for $card_id after $((REPAIR_ATTEMPT + 1)) attempt(s)"
  fi
  REPAIR_ATTEMPT=$((REPAIR_ATTEMPT + 1))
  log "Running repair ${REPAIR_ATTEMPT}/${MAX_FIX_ATTEMPTS} for $card_id"
  repair_prompt="${ACTIVE_RUN_DIR}/repair-${REPAIR_ATTEMPT}-prompt.md"
  make_repair_prompt "$card_id" "$repair_prompt" "$FAILED_CHECK_LOG"
  run_grok "$repair_prompt" "${ACTIVE_RUN_DIR}/repair-${REPAIR_ATTEMPT}-grok.log" ||
    fail "grok repair failed for $card_id"
  restore_out_of_scope_paths
}

verify_commit_contract() {
  local commit="$1"
  local card_id="$2"
  local ticket_id="$3"
  local source_task="$4"
  local message
  local subject

  message="$(git -C "$ACTIVE_WORKTREE" show -s --format='%B' "$commit")"
  subject="$(git -C "$ACTIVE_WORKTREE" show -s --format='%s' "$commit")"
  [[ "$subject" == *"$card_id"* ]] || fail "Commit subject does not contain $card_id"
  grep -Fxq "Execution-Card: $card_id" <<< "$message" || fail "Missing Execution-Card trailer"
  grep -Fxq "Beadwork-Issue: $ticket_id" <<< "$message" || fail "Missing Beadwork-Issue trailer"
  if [ -n "$source_task" ]; then
    grep -Fxq "Source-Roadmap-Task: $source_task" <<< "$message" || fail "Missing source-task trailer"
  fi
  grep -Fxq "Execution-Card-Hash: $CURRENT_CARD_HASH" <<< "$message" || fail "Missing card-hash trailer"
}

collect_changed_paths_from_commit() {
  local baseline="$1"
  local implementation_commit="$2"
  local path
  CHANGED_PATHS=()
  while IFS= read -r path; do
    append_changed_path "$path"
  done < <(git -C "$REPO_ROOT" diff --name-only "$baseline" "$implementation_commit")
}

write_receipt() {
  local card_id="$1"
  local ticket_id="$2"
  local source_task="$3"
  local baseline="$4"
  local implementation_commit="$5"
  local receipt_dir="${RECEIPTS_ROOT}/${card_id}"
  local receipt="${receipt_dir}/${implementation_commit}.json"
  local index
  local comma
  local path
  local approval

  mkdir -p "$receipt_dir"
  [ ! -e "$receipt" ] || fail "Receipt already exists: $receipt"

  {
    printf '{\n'
    printf '  "card_id": "%s",\n' "$(json_escape "$card_id")"
    printf '  "ticket_id": "%s",\n' "$(json_escape "$ticket_id")"
    printf '  "source_roadmap_task": "%s",\n' "$(json_escape "$source_task")"
    printf '  "card_sha256": "%s",\n' "$CURRENT_CARD_HASH"
    printf '  "baseline_commit": "%s",\n' "$baseline"
    printf '  "implementation_commit": "%s",\n' "$implementation_commit"
    printf '  "harness": "grok",\n'
    printf '  "harness_version": "%s",\n' "$(json_escape "$GROK_VERSION")"
    printf '  "changed_paths": ['
    comma=""
    for path in "${CHANGED_PATHS[@]}"; do
      printf '%s"%s"' "$comma" "$(json_escape "$path")"
      comma=", "
    done
    printf '],\n'
    printf '  "commands": [\n'
    for ((index = 0; index < ${#CHECK_COMMANDS[@]}; index++)); do
      [ "$index" -eq 0 ] || printf ',\n'
      printf '    {"command": "%s", "exit_code": %s, "output": "%s"}' \
        "$(json_escape "${CHECK_COMMANDS[$index]}")" \
        "${CHECK_EXIT_CODES[$index]}" \
        "$(json_escape "${CHECK_OUTPUTS[$index]}")"
    done
    printf '\n  ],\n'
    printf '  "git_diff_check_exit_code": 0,\n'
    printf '  "gate_decisions": ['
    comma=""
    for approval in "${GATE_APPROVALS[@]-}"; do
      if [[ "$approval" == "${card_id}:"* || "$approval" == "${ticket_id}:"* ]]; then
        printf '%s{"card_id": "%s", "ticket_id": "%s", "gate": "%s", "reason": "CLI approval for this run", "decision": "approved", "reviewer": "%s", "date": "%s", "evidence": "%s"}' \
          "$comma" \
          "$(json_escape "$card_id")" \
          "$(json_escape "$ticket_id")" \
          "$(json_escape "${approval#*:}")" \
          "$(json_escape "$GATE_REVIEWER")" \
          "$GATE_DECISION_DATE" \
          "$(json_escape "--approve-gate $approval")"
        comma=", "
      fi
    done
    printf '],\n'
    printf '  "accepted": true,\n'
    printf '  "accepted_at": "%s"\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '}\n'
  } > "$receipt"
  log "Accepted receipt: $receipt"
}

blocker_status() {
  local blocker_id="$1"
  local status
  status="$(ticket_field "$blocker_id" "status" || true)"
  if [ -n "$status" ]; then
    printf '%s\n' "$status"
    return 0
  fi
  bw show "$blocker_id" --json | jq -r '.status // empty'
}

ticket_is_blocked() {
  local ticket_id="$1"
  local blocked
  blocked="$(ticket_field "$ticket_id" "blocked" || true)"
  [ "$blocked" = "true" ]
}

validate_dependencies() {
  local ticket_id="$1"
  local blocker
  local status
  local blocker_card

  while IFS= read -r blocker; do
    [ -z "$blocker" ] && continue
    status="$(blocker_status "$blocker")"
    if [ "$status" = "closed" ]; then
      continue
    fi
    blocker_card="$(card_id_for "$blocker" || true)"
    if [ -n "$blocker_card" ] && accepted_commit_for "$blocker_card" "$blocker" >/dev/null; then
      continue
    fi
    fail "Dependency is not closed and has no accepted evidence: $blocker"
  done < <(jq -r --arg id "$ticket_id" '
    .[] | select(.id == $id) | (.blocked_by // [])[]?
  ' "$TICKETS_JSON")
}

claim_ticket() {
  local ticket_id="$1"
  local status
  status="$(ticket_field "$ticket_id" "status" || true)"
  if [ "$status" = "in_progress" ]; then
    log "Ticket $ticket_id is already in_progress"
    return 0
  fi
  log "Claiming beadwork ticket $ticket_id"
  bw start "$ticket_id" || fail "bw start failed for $ticket_id"
  mark_ticket_status "$ticket_id" "in_progress"
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    fail "bw start left the main worktree dirty"
  fi
}

close_ticket() {
  local ticket_id="$1"
  local implementation_commit="$2"
  log "Closing beadwork ticket $ticket_id"
  bw comment "$ticket_id" "Accepted at ${implementation_commit} by ralph_wiggum_loop_v2.sh" ||
    log "WARNING: bw comment failed for $ticket_id"
  bw close "$ticket_id" --reason "Accepted ${implementation_commit}" ||
    fail "bw close failed for $ticket_id"
  mark_ticket_status "$ticket_id" "closed"
  if ! bw sync; then
    log "WARNING: bw sync failed after closing $ticket_id"
  fi
}

prepare_worktree() {
  local card_id="$1"
  local baseline="$2"
  ACTIVE_WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/llmux-${card_id}.XXXXXX")"
  git -C "$REPO_ROOT" worktree add --detach "$ACTIVE_WORKTREE" "$baseline" >/dev/null
  if [ "$RALPH_MIX_CACHE" != "0" ]; then
    export MIX_DEPS_PATH="${REPO_ROOT}/deps"
    export MIX_BUILD_PATH="${REPO_ROOT}/_build"
    # Keep the shared cache paths visible to agents that inspect deps/ or _build/
    # relative to the isolated worktree.
    [ -e "${ACTIVE_WORKTREE}/deps" ] || ln -s "$MIX_DEPS_PATH" "${ACTIVE_WORKTREE}/deps"
    [ -e "${ACTIVE_WORKTREE}/_build" ] || ln -s "$MIX_BUILD_PATH" "${ACTIVE_WORKTREE}/_build"
  fi
}

remove_worktree() {
  local worktree="$1"
  git -C "$REPO_ROOT" worktree remove --force "$worktree"
  ACTIVE_WORKTREE=""
}

run_ticket() {
  local ordinal="$1"
  local ticket_id="$2"
  local card_id
  local source_task
  local title
  local baseline
  local initial_head
  local implementation_commit
  local prompt_file
  local grok_log
  local card_file
  local state

  card_id="$(card_id_for "$ticket_id")"
  [ -n "$card_id" ] || fail "Ticket is missing an id: $ticket_id"
  source_task="$(ticket_field "$ticket_id" "source_task" || true)"
  card_file="${ACTIVE_RUN_PARENT}/${ticket_id}.md"
  mkdir -p "$ACTIVE_RUN_PARENT"
  write_ticket_body "$ticket_id" "$card_file"
  title="$(card_title "$card_id" "$card_file")"
  [ -n "$title" ] || fail "Ticket title is empty: $ticket_id"

  state="$(card_state "$card_id" "$ticket_id")"
  if [ "$state" = "complete" ]; then
    log "Skipping completed ticket $ticket_id ($card_id)"
    return 0
  fi
  if [ "$state" = "commit-without-accepted-receipt" ]; then
    fail "$card_id has a commit but no accepted receipt; recover it before a new run"
  fi
  if [ "$INCLUDE_BLOCKED" -eq 0 ] && ticket_is_blocked "$ticket_id"; then
    if [ -n "$ONLY_TICKET" ]; then
      fail "$ticket_id is still blocked by an open beadwork dependency"
    fi
    log "Skipping blocked ticket $ticket_id ($card_id)"
    return 0
  fi

  validate_dependencies "$ticket_id"
  assert_clean_main_tree
  CURRENT_CARD_HASH="$(card_hash "$card_file")"
  load_allowed_scopes "$card_file"
  load_verification_commands "$card_file"
  enforce_pre_run_gates "$card_id" "$ticket_id" "$card_file"

  if [ "$DO_CLAIM" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    claim_ticket "$ticket_id"
  fi

  baseline="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  prepare_worktree "$card_id" "$baseline"
  initial_head="$(git -C "$ACTIVE_WORKTREE" rev-parse HEAD)"
  ACTIVE_RUN_DIR="${RUNS_ROOT}/${card_id}/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  mkdir -p "$ACTIVE_RUN_DIR"
  cp "$card_file" "${ACTIVE_RUN_DIR}/ticket.md"
  card_file="${ACTIVE_RUN_DIR}/ticket.md"
  CHECK_ROUND=0
  REPAIR_ATTEMPT=0
  prompt_file="${ACTIVE_RUN_DIR}/implementation-prompt.md"
  grok_log="${ACTIVE_RUN_DIR}/grok.log"

  log "Ticket ${ordinal}: ${ticket_id} / ${card_id} - ${title}"
  make_implementation_prompt "$card_id" "$ticket_id" "$source_task" "$card_file" "$prompt_file"
  run_grok "$prompt_file" "$grok_log" || fail "grok failed for $ticket_id"
  restore_out_of_scope_paths

  [ "$(git -C "$ACTIVE_WORKTREE" rev-parse HEAD)" = "$initial_head" ] ||
    fail "grok created a commit; the runner must own commits"
  [ "$(card_hash "$card_file")" = "$CURRENT_CARD_HASH" ] ||
    fail "Ticket content changed during execution"

  # Repository rules require the focused checks and full gate before commit.
  while ! run_all_checks 0 "$card_id" "$ticket_id"; do
    run_repair "$card_id"
  done
  stage_and_commit "$card_id" "$ticket_id" "$source_task" "$title" 0

  # The execution contract also requires the same checks from the commit. A
  # repair is checked before the runner amends the single card commit.
  while ! run_all_checks 1 "$card_id" "$ticket_id"; do
    run_repair "$card_id"
    while ! run_all_checks 0 "$card_id" "$ticket_id"; do
      run_repair "$card_id"
    done
    stage_and_commit "$card_id" "$ticket_id" "$source_task" "$title" 1
  done

  implementation_commit="$(git -C "$ACTIVE_WORKTREE" rev-parse HEAD)"
  verify_commit_contract "$implementation_commit" "$card_id" "$ticket_id" "$source_task"
  git -C "$ACTIVE_WORKTREE" diff --check "${baseline}..${implementation_commit}"

  assert_clean_main_tree
  [ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$baseline" ] ||
    fail "The target branch changed while $ticket_id was running"
  git -C "$REPO_ROOT" merge --ff-only "$implementation_commit"

  collect_changed_paths_from_commit "$baseline" "$implementation_commit"
  write_receipt "$card_id" "$ticket_id" "$source_task" "$baseline" "$implementation_commit"
  [ "$(accepted_commit_for "$card_id" "$ticket_id")" = "$implementation_commit" ] ||
    fail "The accepted commit check failed after receipt creation for $ticket_id"

  if [ "$DO_PUSH" -eq 1 ]; then
    git -C "$REPO_ROOT" push "$REMOTE_NAME" "HEAD:${TARGET_BRANCH}"
  fi

  if [ "$DO_CLOSE" -eq 1 ]; then
    close_ticket "$ticket_id" "$implementation_commit"
  fi

  remove_worktree "$ACTIVE_WORKTREE"
  log "Completed $ticket_id ($card_id) at $implementation_commit"
}

load_beadwork_tickets() {
  local raw="${STATE_DIR}/tickets-raw.json"
  log "Loading beadwork tickets"
  bw list --all --json > "$raw" || fail "bw list --all --json failed"
  jq '
    (if . == null then [] elif type == "array" then . else [.] end)
    | map({
        id,
        title: (.title // ""),
        status: (.status // "open"),
        type: (.type // "task"),
        priority: (.priority // 2),
        description: (.description // ""),
        blocked_by: (.blocked_by // []),
        labels: (.labels // []),
        parent: (.parent // ""),
        card_id: (
          ((.title // "") | capture("(?<id>EX-M[0-9]+-E[0-9]+-T[0-9]+-[0-9]+)"; "i")? | .id)
          // .id
        ),
        source_task: (
          ((.description // "") | capture("Source roadmap task: `(?<id>[^`]+)`")? | .id)
          // ""
        ),
        ordinal: (
          ((.description // "") | capture("Queue ordinal: `(?<n>[0-9]+)`")? | .n | tonumber?)
          // 99999
        )
      })
    | . as $items
    | ($items | map({key: .id, value: .status}) | from_entries) as $status_by_id
    | $items
    | map(. + {
        blocked: (
          [.blocked_by[]? | ($status_by_id[.] // "open")]
          | any(. != "closed")
        )
      })
  ' "$raw" > "$TICKETS_JSON" || fail "Failed to normalize beadwork tickets"
}

select_tickets() {
  local record
  local ticket_id
  local card_id
  local status
  local ordinal
  local blocked
  local start_found=0
  local end_found=0

  SELECTED_IDS=()
  [ -z "$START_AT" ] && start_found=1

  while IFS= read -r record; do
    [ -z "$record" ] && continue
    ticket_id="$(jq -r '.id' <<< "$record")"
    card_id="$(jq -r '.card_id' <<< "$record")"
    status="$(jq -r '.status' <<< "$record")"
    ordinal="$(jq -r '.ordinal' <<< "$record")"
    blocked="$(jq -r '.blocked' <<< "$record")"

    if [ -n "$ONLY_TICKET" ] &&
      [ "$ticket_id" != "$ONLY_TICKET" ] &&
      [ "$card_id" != "$ONLY_TICKET" ]; then
      continue
    fi

    if [ "$start_found" -eq 0 ]; then
      if [ "$ticket_id" = "$START_AT" ] || [ "$card_id" = "$START_AT" ]; then
        start_found=1
      else
        continue
      fi
    fi

    if [ -z "$ONLY_TICKET" ]; then
      [ "$status" = "closed" ] && continue
      if [ "$INCLUDE_BLOCKED" -eq 0 ] && [ "$blocked" = "true" ]; then
        continue
      fi
    fi

    SELECTED_IDS+=("${ordinal}|${ticket_id}|${card_id}|${status}")

    if [ -n "$END_AT" ] && { [ "$ticket_id" = "$END_AT" ] || [ "$card_id" = "$END_AT" ]; }; then
      end_found=1
      break
    fi
    if [ "$MAX_TICKETS" -gt 0 ] && [ "${#SELECTED_IDS[@]}" -ge "$MAX_TICKETS" ]; then
      break
    fi
  done < <(jq -c 'map(select(.type == "task")) | sort_by(.ordinal, .id) | .[]' "$TICKETS_JSON")

  [ -z "$ONLY_TICKET" ] || [ "${#SELECTED_IDS[@]}" -eq 1 ] || fail "Ticket not found: $ONLY_TICKET"
  [ -z "$START_AT" ] || [ "$start_found" -eq 1 ] || fail "Start ticket not found: $START_AT"
  [ -z "$END_AT" ] || [ "$end_found" -eq 1 ] || fail "End ticket not found in selected range: $END_AT"
  [ "${#SELECTED_IDS[@]}" -gt 0 ] || fail "No beadwork tickets selected"
}

START_AT=""
END_AT=""
ONLY_TICKET=""
MAX_TICKETS=0
DRY_RUN=0
DO_PUSH=0
DO_CLAIM=1
DO_CLOSE=1
INCLUDE_BLOCKED=0
REMOTE_NAME="origin"
TARGET_BRANCH=""
GROK_MODEL="${RALPH_GROK_MODEL:-grok-4.6}"
GROK_PERMISSION_MODE="acceptEdits"
GROK_EXTRA_ARGS=()
MAX_FIX_ATTEMPTS=2
GATE_APPROVALS=()
GATE_REVIEWER="${GATE_REVIEWER:-}"
GATE_DECISION_DATE="$(date -u '+%Y-%m-%d')"
RALPH_MIX_CACHE="${RALPH_MIX_CACHE:-1}"
LOG_FILE="${LOG_FILE:-}"
ACTIVE_WORKTREE=""
TICKETS_JSON=""
SELECTED_IDS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --start-at)
      require_value "$1" "$#" "${2:-}"
      START_AT="$2"
      shift 2
      ;;
    --end-at)
      require_value "$1" "$#" "${2:-}"
      END_AT="$2"
      shift 2
      ;;
    --only)
      require_value "$1" "$#" "${2:-}"
      ONLY_TICKET="$2"
      shift 2
      ;;
    --max)
      require_value "$1" "$#" "${2:-}"
      MAX_TICKETS="$2"
      shift 2
      ;;
    --model)
      require_value "$1" "$#" "${2:-}"
      GROK_MODEL="$2"
      shift 2
      ;;
    --permission-mode)
      require_value "$1" "$#" "${2:-}"
      GROK_PERMISSION_MODE="$2"
      shift 2
      ;;
    --grok-arg)
      [ "$#" -ge 2 ] || fail "Option $1 requires a value"
      GROK_EXTRA_ARGS+=("$2")
      shift 2
      ;;
    --max-fix-attempts)
      require_value "$1" "$#" "${2:-}"
      MAX_FIX_ATTEMPTS="$2"
      shift 2
      ;;
    --approve-gate)
      require_value "$1" "$#" "${2:-}"
      validate_approval_format "$2"
      GATE_APPROVALS+=("$2")
      shift 2
      ;;
    --include-blocked)
      INCLUDE_BLOCKED=1
      shift
      ;;
    --no-claim)
      DO_CLAIM=0
      shift
      ;;
    --no-close)
      DO_CLOSE=0
      shift
      ;;
    --push)
      DO_PUSH=1
      shift
      ;;
    --remote)
      require_value "$1" "$#" "${2:-}"
      REMOTE_NAME="$2"
      shift 2
      ;;
    --branch)
      require_value "$1" "$#" "${2:-}"
      TARGET_BRANCH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

is_non_negative_integer "$MAX_TICKETS" || fail "--max must be a non-negative integer"
is_non_negative_integer "$MAX_FIX_ATTEMPTS" || fail "--max-fix-attempts must be a non-negative integer"

command -v git >/dev/null 2>&1 || fail "git is required"
command -v rg >/dev/null 2>&1 || fail "ripgrep is required"
command -v shasum >/dev/null 2>&1 || fail "shasum is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v bw >/dev/null 2>&1 || fail "bw (beadwork) is required"
command -v uuidgen >/dev/null 2>&1 || fail "uuidgen is required"
if [ "$DRY_RUN" -eq 0 ]; then
  command -v grok >/dev/null 2>&1 || fail "grok is required"
  command -v mix >/dev/null 2>&1 || fail "mix is required"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" ||
  fail "The runner must be stored inside the llmux Git repository"
cd "$REPO_ROOT"

CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ -n "$CURRENT_BRANCH" ] || fail "Detached HEAD is not supported"
if [ -z "$TARGET_BRANCH" ]; then
  TARGET_BRANCH="$CURRENT_BRANCH"
fi
[ "$TARGET_BRANCH" = "$CURRENT_BRANCH" ] || fail "--branch must equal the checked-out branch: $CURRENT_BRANCH"

COMMON_GIT_DIR="$(git rev-parse --git-common-dir)"
if [[ "$COMMON_GIT_DIR" != /* ]]; then
  COMMON_GIT_DIR="${REPO_ROOT}/${COMMON_GIT_DIR}"
fi
COMMON_GIT_DIR="$(absolute_dir "$COMMON_GIT_DIR")"
RECEIPTS_ROOT="${COMMON_GIT_DIR}/llmux-execution/receipts"
RUNS_ROOT="${COMMON_GIT_DIR}/llmux-execution/runs"
STATE_DIR="${COMMON_GIT_DIR}/llmux-execution/v2-state/$$"
ACTIVE_RUN_PARENT="${STATE_DIR}/tickets"
TICKETS_JSON="${STATE_DIR}/tickets.json"
mkdir -p "$RECEIPTS_ROOT" "$RUNS_ROOT" "$ACTIVE_RUN_PARENT"
if [ -z "$GATE_REVIEWER" ]; then
  GATE_REVIEWER="$(git config user.name || true)"
fi
if [ -z "$GATE_REVIEWER" ]; then
  GATE_REVIEWER="${USER:-unknown}"
fi
if [ -z "$LOG_FILE" ]; then
  LOG_FILE="${COMMON_GIT_DIR}/llmux-execution/ralph-v2.log"
fi
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

build_grok_command
if [ "$DRY_RUN" -eq 0 ]; then
  GROK_VERSION="$(grok --version 2>&1 | head -n 1 || true)"
else
  GROK_VERSION="not-invoked"
fi

load_beadwork_tickets
select_tickets

log "Repository: $REPO_ROOT"
log "Branch: $TARGET_BRANCH"
log "Ticket source: beadwork"
log "Selected tickets: ${#SELECTED_IDS[@]}"
log "Push enabled: $DO_PUSH"
log "Claim tickets: $DO_CLAIM"
log "Close tickets: $DO_CLOSE"

if [ "$DRY_RUN" -eq 1 ]; then
  for record in "${SELECTED_IDS[@]}"; do
    IFS='|' read -r ordinal ticket_id card_id status <<< "$record"
    printf '%3s. %-28s %-32s [%-32s] %s\n' \
      "$ordinal" "$ticket_id" "$card_id" "$(card_state "$card_id" "$ticket_id")" "$status"
  done
  exit 0
fi

assert_clean_main_tree
for record in "${SELECTED_IDS[@]}"; do
  IFS='|' read -r ordinal ticket_id card_id status <<< "$record"
  run_ticket "$ordinal" "$ticket_id"
done

log "Selected beadwork tickets are complete."
