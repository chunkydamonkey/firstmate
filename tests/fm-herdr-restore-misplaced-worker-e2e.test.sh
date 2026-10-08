#!/usr/bin/env bash
# Real Herdr regression for a task agent that a session restore resumes outside
# its worktree.
#
# A spawned worker's pane is created in the main project copy and only its
# `treehouse get` subshell enters the worktree. Herdr persists the pane's
# top-level shell directory, so a restore re-runs the agent's resume command in
# the main copy. This reproduces that with a token-free stand-in agent named
# `claude` that registers its session through Herdr's own session API, then
# proves the production guards: the misplaced-worker predicate names the main
# copy, the doorbell types nothing, and the watcher surfaces the worker once.
#
# Every Herdr call runs in one guarded named non-default lab, and lab teardown
# verifies the default fleet session is unchanged.
# shellcheck disable=SC2016 # Single-quoted scripts expand in the child bash or eval that runs them.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v git >/dev/null 2>&1 || { echo 'skip: git not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo 'skip: sleep not found'; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-restore-misplaced.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
AGENTBIN="$TMP_ROOT/agentbin"
HOME_DIR="$TMP_ROOT/home"
MAIN="$TMP_ROOT/main"
WT="$TMP_ROOT/pool/wt"
AGENT_LOG="$TMP_ROOT/agent.log"
SID=0f1e2d3c-4b5a-4697-8877-665544332211
mkdir -p "$FAKEBIN" "$AGENTBIN/libexec" "$HOME_DIR/state" "$HOME_DIR/config"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-restore-misplaced)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" viewer stop "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

git init -q "$MAIN" || fail 'could not create the main copy'
git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init \
  || fail 'could not commit in the main copy'
mkdir -p "${WT%/*}"
git -C "$MAIN" worktree add -q "$WT" -b task || fail 'could not create the task worktree'

# The stand-in agent: logs where it runs and with what arguments, registers
# its session the way Herdr's Claude integration does, then becomes a process
# named `claude` so both Herdr and the harness-process classifier see an agent.
cp "$SLEEP_BIN" "$AGENTBIN/libexec/claude"
cat > "$AGENTBIN/claude" <<SH
#!/usr/bin/env bash
printf 'pwd=%s args=%s\n' "\$PWD" "\$*" >> '$AGENT_LOG'
( sleep 1
  env PATH='$HERDR_ORIGINAL_PATH' '$HERDR_LAB_HELPER' run '$HERDR_LAB_SESSION' pane report-agent-session \
    "\$HERDR_PANE_ID" --source herdr:claude --agent claude --agent-session-id '$SID' >/dev/null 2>&1 ) &
exec '$AGENTBIN/libexec/claude' 100000
SH
# Panes start this shell, so a restored pane resolves `claude` to the stand-in
# without reading the operator's shell startup files.
cat > "$AGENTBIN/labshell" <<SH
#!/usr/bin/env bash
export PATH='$AGENTBIN':"\$PATH"
exec /bin/bash --norc "\$@"
SH
chmod +x "$AGENTBIN/claude" "$AGENTBIN/labshell"

# Production adapter calls append the exact lab session; this shim strips that
# pair, refuses every other caller-supplied session, and delegates to helper run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
provision() {
  env SHELL="$AGENTBIN/labshell" PATH="$AGENTBIN:$HERDR_ORIGINAL_PATH" \
    "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null
}
pane_field() {  # <jq-filter>
  lab pane get "$PANE" 2>/dev/null | jq -r "$1" 2>/dev/null
}
production() {  # <bash-script> [args...]
  local script=$1
  shift
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c "$script" _ "$ROOT" "$@"
}
outside() {
  production '. "$1/bin/fm-backend.sh"; fm_backend_task_outside_worktree "$2"' "$HOME_DIR/state/t1.meta"
}
wait_for() {  # <tries> <command...>
  local tries=$1 i=0
  shift
  while [ "$i" -lt "$tries" ]; do
    "$@" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

provision || fail 'could not provision the named lab'
WS_JSON=$(lab workspace create --cwd "$MAIN" --label restore-misplaced --no-focus) || fail 'could not create the workspace'
WS=$(printf '%s' "$WS_JSON" | jq -r '.result.workspace.workspace_id')
TAB_JSON=$(lab tab create --workspace "$WS" --cwd "$MAIN" --label fm-t1 --no-focus) || fail 'could not create the task tab'
PANE=$(printf '%s' "$TAB_JSON" | jq -r '.result.root_pane.pane_id')
TAB=$(printf '%s' "$TAB_JSON" | jq -r '.result.tab.tab_id')
[ -n "$PANE" ] && [ "$PANE" != null ] || fail "tab create returned no pane: $TAB_JSON"

# The spawn shape: the top-level shell stays in the main copy while an
# interactive subshell enters the worktree, then the agent starts there.
lab pane send-text "$PANE" "bash --norc -c 'cd \"\$1\" && exec bash --norc -i' _ '$WT'" >/dev/null || fail 'could not type the subshell'
lab pane send-keys "$PANE" Enter >/dev/null || fail 'could not enter the subshell'
wait_for 30 eval '[ "$(pane_field ".result.pane.foreground_cwd // empty")" = "$WT" ]' \
  || fail "the pane never entered the worktree subshell (foreground $(pane_field .result.pane.foreground_cwd))"
lab pane send-text "$PANE" 'claude --dangerously-skip-permissions' >/dev/null || fail 'could not type the agent launch'
lab pane send-keys "$PANE" Enter >/dev/null || fail 'could not start the agent'
wait_for 40 eval '[ "$(pane_field ".result.pane.agent_session.value // empty")" = "$SID" ]' \
  || fail "the stand-in agent never registered its session: $(lab pane get "$PANE")"

{
  printf 'window=%s:%s\n' "$HERDR_LAB_SESSION" "$PANE"
  printf 'endpoint_task_id=fm-t1\n'
  printf 'worktree=%s\n' "$WT"
  printf 'project=%s\n' "$MAIN"
  printf 'harness=claude\nkind=ship\nbackend=herdr\n'
  printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
    "$HERDR_LAB_SESSION" "$WS" "$TAB" "$PANE"
} > "$HOME_DIR/state/t1.meta"

out=$(outside) && fail "an agent running in its worktree was reported outside it: $out"
pass 'a live agent in its worktree subshell is not reported'

env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'could not stop the named lab'
provision || fail 'could not restore the named lab'
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION" >/dev/null \
  || fail 'could not attach a viewer to the restored lab'
lab tab focus "$TAB" >/dev/null 2>&1 || true
wait_for 60 grep -qF "args=--resume $SID" "$AGENT_LOG" \
  || fail "the restore never resumed the agent: $(cat "$AGENT_LOG" 2>/dev/null)"
grep -qxF "pwd=$MAIN args=--resume $SID" "$AGENT_LOG" \
  || fail "the restored agent did not resume in the main copy, which this regression depends on: $(cat "$AGENT_LOG")"
pass 'a Herdr restore resumes the agent in the main copy the pane was created in'

wait_for 40 eval 'out=$(outside)' || fail "the resumed agent in the main copy was never reported outside its worktree"
[ "$out" = "$MAIN" ] || fail "the misplaced agent should be reported in '$MAIN', got '$out'"
pass 'the resumed agent is reported outside its recorded worktree, naming the main copy'

REC=$(production '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" t1 "please continue"' "$HOME_DIR/state") \
  || fail 'could not write a steering record'
rc=0
production '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_ring herdr "$2" "$3" fm-t1; rc=$?; printf "%s" "$FM_TASK_INBOX_MISPLACED_DIR" > "$4"; exit "$rc"' \
  "$HERDR_LAB_SESSION:$PANE" "$REC" "$TMP_ROOT/ring-dir" || rc=$?
[ "$rc" -eq 4 ] || fail "the doorbell to a misplaced agent should return 4, got $rc"
[ "$(cat "$TMP_ROOT/ring-dir")" = "$MAIN" ] || fail "the refused ring should name the main copy, got '$(cat "$TMP_ROOT/ring-dir")'"
sleep 1
if lab pane read "$PANE" --source recent --lines 40 2>/dev/null | grep -qF 'Firstmate instruction waiting'; then
  fail 'the doorbell was typed into the misplaced agent'
fi
[ -f "$REC" ] || fail 'the refused ring must leave the steering record in place'
pass 'the doorbell types nothing into the misplaced agent and keeps the record'

WATCH_CHECK='
  . "$1/bin/fm-watch.sh"
  wake() { printf "WAKE %s\n" "$1"; exit 0; }
  misplaced_worker_check "$2" t1
  printf "QUIET %s\n" "$?"'
first=$(production "$WATCH_CHECK" "$HERDR_LAB_SESSION:$PANE") || fail "the watcher check failed: $first"
case "$first" in
  "WAKE stale: $HERDR_LAB_SESSION:$PANE (worker agent runs in $MAIN, outside its recorded worktree $WT,"*) ;;
  *) fail "the watcher should surface the misplaced worker once, got: $first" ;;
esac
second=$(production "$WATCH_CHECK" "$HERDR_LAB_SESSION:$PANE") || fail "the repeated watcher check failed: $second"
[ "$second" = 'QUIET 0' ] || fail "the same misplaced directory must be surfaced only once, got: $second"
pass 'the watcher surfaces a misplaced worker once and skips its other checks'
