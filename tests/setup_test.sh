#!/usr/bin/env bash

set -u -o pipefail

export LC_ALL=C

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
setup_script="${repo_root}/setup.sh"
real_mkdir=$(command -v mkdir)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/agents-setup-test.XXXXXX")

declare -a skill_names=()
shopt -s nullglob
for skill_dir in "${repo_root}"/skills/*; do
  if [[ -d "$skill_dir" && -f "${skill_dir}/SKILL.md" ]]; then
    skill_names+=("${skill_dir##*/}")
  fi
done
shopt -u nullglob

RUN_OUTPUT=''
RUN_STATUS=0
CURRENT_TEST='setup tests'
passed=0
failed=0

cleanup() {
  if [[ -n "${test_root:-}" && -d "$test_root" ]]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s: %s\n' "$CURRENT_TEST" "$*" >&2
  exit 1
}

assert_eq() {
  local expected=$1
  local actual=$2
  local context=$3
  if [[ "$actual" != "$expected" ]]; then
    fail "${context}: expected [${expected}], got [${actual}]"
  fi
}

assert_status() {
  assert_eq "$1" "$RUN_STATUS" "exit status"
}

assert_output_contains() {
  local expected=$1
  if [[ "$RUN_OUTPUT" != *"$expected"* ]]; then
    fail "output does not contain [${expected}]; output was [${RUN_OUTPUT}]"
  fi
}

assert_output_prefix_count() {
  local expected=$1
  local prefix=$2
  local actual
  actual=$(awk -v prefix="$prefix" 'index($0, prefix) == 1 { count++ } END { print count + 0 }' <<<"$RUN_OUTPUT")
  assert_eq "$expected" "$actual" "lines beginning with ${prefix}"
}

assert_absent() {
  local path=$1
  if [[ -e "$path" || -L "$path" ]]; then
    fail "expected path to be absent: ${path}"
  fi
}

assert_directory() {
  local path=$1
  if [[ ! -d "$path" || -L "$path" ]]; then
    fail "expected a real directory: ${path}"
  fi
}

assert_regular_file() {
  local path=$1
  if [[ ! -f "$path" || -L "$path" ]]; then
    fail "expected a regular file: ${path}"
  fi
}

assert_link_target() {
  local path=$1
  local expected=$2
  local actual
  if [[ ! -L "$path" ]]; then
    fail "expected a symbolic link: ${path}"
  fi
  actual=$(readlink -- "$path") || fail "could not read link: ${path}"
  assert_eq "$expected" "$actual" "link target for ${path}"
}

assert_file_text() {
  local path=$1
  local expected=$2
  local actual
  assert_regular_file "$path"
  actual=$(<"$path")
  assert_eq "$expected" "$actual" "contents of ${path}"
}

capture() {
  RUN_OUTPUT=$("$@" 2>&1)
  RUN_STATUS=$?
}

new_case_root() {
  mktemp -d "${test_root}/case.XXXXXX"
}

current_link_count() {
  printf '%s\n' "$((2 + 2 * ${#skill_names[@]}))"
}

assert_current_install() {
  local home=$1
  local codex_root=$2
  local claude_root=$3
  local skill_name

  assert_link_target "${codex_root}/AGENTS.md" "${repo_root}/RULES.md"
  assert_link_target "${claude_root}/CLAUDE.md" "${repo_root}/RULES.md"
  for skill_name in "${skill_names[@]}"; do
    assert_link_target \
      "${home}/.agents/skills/${skill_name}" \
      "${repo_root}/skills/${skill_name}"
    assert_link_target \
      "${claude_root}/skills/${skill_name}" \
      "${repo_root}/skills/${skill_name}"
  done
}

snapshot_tree() {
  local root=$1
  (
    cd -- "$root" || exit 1
    find . -mindepth 1 -printf '%P|%y|%l\n' | sort
  )
}

write_mkdir_race_wrapper() {
  local bin_dir=$1
  mkdir -p -- "$bin_dir" || fail "could not create fake command directory"
  cat >"${bin_dir}/mkdir" <<'EOF'
#!/usr/bin/env bash

set -eu

if [[ ! -e "$TEST_RACE_MARKER" ]]; then
  "$TEST_REAL_MKDIR" -p -- "$(dirname -- "$TEST_RACE_TARGET")"
  : >"$TEST_RACE_MARKER"
  case "$TEST_RACE_MODE" in
    appear)
      printf 'appeared during setup\n' >"$TEST_RACE_TARGET"
      ;;
    replace)
      unlink -- "$TEST_RACE_TARGET"
      ln -s -- "$TEST_RACE_REPLACEMENT" "$TEST_RACE_TARGET"
      ;;
    *)
      printf 'unknown race mode: %s\n' "$TEST_RACE_MODE" >&2
      exit 64
      ;;
  esac
fi

exec "$TEST_REAL_MKDIR" "$@"
EOF
  chmod +x "${bin_dir}/mkdir" || fail "could not make fake mkdir executable"
}

test_help_and_argument_validation() {
  local case_root
  case_root=$(new_case_root) || fail "could not create case root"

  capture "$setup_script" --help
  assert_status 0
  assert_output_contains 'Usage: setup.sh [--dry-run] [--target-home DIRECTORY]'

  capture "$setup_script" -h
  assert_status 0
  assert_output_contains 'Usage: setup.sh'

  capture "$setup_script" --unknown
  assert_status 2
  assert_output_contains 'Usage: setup.sh'

  capture "$setup_script" --target-home
  assert_status 2
  assert_output_contains 'Usage: setup.sh'

  capture "$setup_script" --target-home ''
  assert_status 2
  assert_output_contains '--target-home must not be empty'

  capture env HOME="${case_root}/home" "$setup_script" --target-home relative
  assert_status 1
  assert_output_contains 'expected an absolute path: relative'

  capture env -u HOME -u CODEX_HOME -u CLAUDE_CONFIG_DIR "$setup_script" --dry-run
  assert_status 1
  assert_output_contains 'HOME is not set'
}

test_target_home_validation() {
  local case_root file_target real_target symlink_target
  case_root=$(new_case_root) || fail "could not create case root"
  file_target="${case_root}/home-file"
  real_target="${case_root}/real-home"
  symlink_target="${case_root}/home-link"
  printf 'not a directory\n' >"$file_target" || fail "could not seed home file"
  mkdir -p -- "$real_target" || fail "could not seed real home"
  ln -s -- "$real_target" "$symlink_target" || fail "could not seed home symlink"

  capture "$setup_script" --target-home "$file_target"
  assert_status 1
  assert_output_contains 'home path is not a directory'

  capture "$setup_script" --target-home "$symlink_target"
  assert_status 1
  assert_output_contains '--target-home must not be a symlink'
}

test_dry_run_makes_no_writes() {
  local case_root target_home expected_count
  case_root=$(new_case_root) || fail "could not create case root"
  target_home="${case_root}/new-home"
  expected_count=$(current_link_count)

  capture env \
    HOME="${case_root}/ignored-home" \
    CODEX_HOME="${case_root}/ignored-codex" \
    CLAUDE_CONFIG_DIR="${case_root}/ignored-claude" \
    "$setup_script" --dry-run --target-home "$target_home"
  assert_status 0
  assert_output_prefix_count "$expected_count" 'would link '
  assert_absent "$target_home"
  assert_absent "${case_root}/ignored-home"
  assert_absent "${case_root}/ignored-codex"
  assert_absent "${case_root}/ignored-claude"
}

test_exact_first_install() {
  local case_root target_home expected_count actual_count directory_count file_count
  case_root=$(new_case_root) || fail "could not create case root"
  target_home="${case_root}/home"
  expected_count=$(current_link_count)

  capture "$setup_script" --target-home "$target_home"
  assert_status 0
  assert_output_prefix_count "$expected_count" 'linked '
  assert_current_install "$target_home" "${target_home}/.codex" "${target_home}/.claude"

  actual_count=$(find "$target_home" -type l -print | awk 'END { print NR + 0 }')
  assert_eq "$expected_count" "$actual_count" 'installed link count'
  directory_count=$(find "$target_home" -mindepth 1 -type d -print | awk 'END { print NR + 0 }')
  assert_eq 5 "$directory_count" 'created directory count'
  file_count=$(find "$target_home" -type f -print | awk 'END { print NR + 0 }')
  assert_eq 0 "$file_count" 'created regular file count'
  assert_absent "${target_home}/.codex/skills"
}

test_environment_routing() {
  local case_root home codex_root claude_root
  case_root=$(new_case_root) || fail "could not create case root"
  home="${case_root}/home"
  codex_root="${case_root}/codex-config"
  claude_root="${case_root}/claude-config"
  mkdir -p -- "$home" || fail "could not create home"

  capture env \
    HOME="$home" \
    CODEX_HOME="$codex_root" \
    CLAUDE_CONFIG_DIR="$claude_root" \
    "$setup_script"
  assert_status 0
  assert_current_install "$home" "$codex_root" "$claude_root"
  assert_absent "${home}/.codex"
  assert_absent "${home}/.claude"
  assert_absent "${codex_root}/skills"
}

test_target_home_overrides_environment_routing() {
  local case_root target_home env_home env_codex env_claude
  case_root=$(new_case_root) || fail "could not create case root"
  target_home="${case_root}/target-home"
  env_home="${case_root}/environment-home"
  env_codex="${case_root}/environment-codex"
  env_claude="${case_root}/environment-claude"

  capture env \
    HOME="$env_home" \
    CODEX_HOME="$env_codex" \
    CLAUDE_CONFIG_DIR="$env_claude" \
    "$setup_script" --target-home "$target_home"
  assert_status 0
  assert_current_install "$target_home" "${target_home}/.codex" "${target_home}/.claude"
  assert_absent "$env_home"
  assert_absent "$env_codex"
  assert_absent "$env_claude"
}

test_idempotent_reinstall() {
  local case_root target_home expected_count first_snapshot second_snapshot
  case_root=$(new_case_root) || fail "could not create case root"
  target_home="${case_root}/home"
  expected_count=$(current_link_count)

  capture "$setup_script" --target-home "$target_home"
  assert_status 0
  first_snapshot=$(snapshot_tree "$target_home") || fail "could not snapshot first install"

  capture "$setup_script" --target-home "$target_home"
  assert_status 0
  assert_output_prefix_count "$expected_count" 'already linked '
  second_snapshot=$(snapshot_tree "$target_home") || fail "could not snapshot reinstall"
  assert_eq "$first_snapshot" "$second_snapshot" 'idempotent filesystem state'
  assert_current_install "$target_home" "${target_home}/.codex" "${target_home}/.claude"
}

test_preserves_unrelated_skills_and_codex_skills() {
  local case_root target_home
  case_root=$(new_case_root) || fail "could not create case root"
  target_home="${case_root}/home"
  mkdir -p -- \
    "${target_home}/.agents/skills/external-skill" \
    "${target_home}/.claude/skills/external-skill" \
    "${target_home}/.codex/skills/bundled-skill" \
    || fail "could not seed unrelated skills"
  printf 'agents external\n' >"${target_home}/.agents/skills/external-skill/owner.txt"
  printf 'claude external\n' >"${target_home}/.claude/skills/external-skill/owner.txt"
  printf 'managed elsewhere\n' >"${target_home}/.codex/skills/bundled-skill/owner.txt"

  capture "$setup_script" --target-home "$target_home"
  assert_status 0
  assert_current_install "$target_home" "${target_home}/.codex" "${target_home}/.claude"
  assert_file_text "${target_home}/.agents/skills/external-skill/owner.txt" 'agents external'
  assert_file_text "${target_home}/.claude/skills/external-skill/owner.txt" 'claude external'
  assert_file_text "${target_home}/.codex/skills/bundled-skill/owner.txt" 'managed elsewhere'
}

test_completes_partial_valid_install() {
  local case_root target_home expected_count
  case_root=$(new_case_root) || fail "could not create case root"
  target_home="${case_root}/home"
  expected_count=$(current_link_count)
  mkdir -p -- "${target_home}/.codex" "${target_home}/.agents/skills" \
    || fail "could not seed partial install directories"
  ln -s -- "${repo_root}/RULES.md" "${target_home}/.codex/AGENTS.md" \
    || fail "could not seed rules link"
  ln -s -- \
    "${repo_root}/skills/${skill_names[0]}" \
    "${target_home}/.agents/skills/${skill_names[0]}" \
    || fail "could not seed skill link"

  capture "$setup_script" --target-home "$target_home"
  assert_status 0
  assert_output_prefix_count 2 'already linked '
  assert_output_prefix_count "$((expected_count - 2))" 'linked '
  assert_current_install "$target_home" "${target_home}/.codex" "${target_home}/.claude"
}

test_aggregates_conflicts_without_writes() {
  local case_root target_home skill_name wrong_source dangling_source before after link_count
  case_root=$(new_case_root) || fail "could not create case root"
  target_home="${case_root}/home"
  skill_name=${skill_names[0]}
  wrong_source="${case_root}/wrong-source"
  dangling_source="${case_root}/missing-source"
  mkdir -p -- \
    "${target_home}/.codex" \
    "${target_home}/.claude/CLAUDE.md" \
    "${target_home}/.agents/skills" \
    "${target_home}/.claude/skills" \
    "$wrong_source" \
    || fail "could not seed conflict directories"
  printf 'keep this file\n' >"${target_home}/.codex/AGENTS.md"
  ln -s -- "$wrong_source" "${target_home}/.agents/skills/${skill_name}" \
    || fail "could not seed wrong link"
  ln -s -- "$dangling_source" "${target_home}/.claude/skills/${skill_name}" \
    || fail "could not seed dangling link"
  before=$(snapshot_tree "$target_home") || fail "could not snapshot conflicts"

  capture "$setup_script" --target-home "$target_home"
  assert_status 1
  assert_output_contains 'found 4 conflict(s); no links were changed'
  after=$(snapshot_tree "$target_home") || fail "could not snapshot conflicts after setup"
  assert_eq "$before" "$after" 'conflict filesystem state'
  assert_file_text "${target_home}/.codex/AGENTS.md" 'keep this file'
  assert_directory "${target_home}/.claude/CLAUDE.md"
  assert_link_target "${target_home}/.agents/skills/${skill_name}" "$wrong_source"
  assert_link_target "${target_home}/.claude/skills/${skill_name}" "$dangling_source"
  link_count=$(find "$target_home" -type l -print | awk 'END { print NR + 0 }')
  assert_eq 2 "$link_count" 'links after rejected conflict set'
}

test_rejects_managed_directory_conflicts_without_writes() {
  local case_root target_home claude_backing before_home after_home before_backing after_backing
  case_root=$(new_case_root) || fail "could not create case root"
  target_home="${case_root}/home"
  claude_backing="${case_root}/claude-backing"
  mkdir -p -- "$target_home" "$claude_backing" || fail "could not seed directories"
  printf 'not a directory\n' >"${target_home}/.codex"
  ln -s -- "$claude_backing" "${target_home}/.claude" \
    || fail "could not seed managed directory link"
  before_home=$(snapshot_tree "$target_home") || fail "could not snapshot home"
  before_backing=$(snapshot_tree "$claude_backing") || fail "could not snapshot backing directory"

  capture "$setup_script" --target-home "$target_home"
  assert_status 1
  assert_output_contains 'found 2 conflict(s); no links were changed'
  after_home=$(snapshot_tree "$target_home") || fail "could not resnapshot home"
  after_backing=$(snapshot_tree "$claude_backing") || fail "could not resnapshot backing directory"
  assert_eq "$before_home" "$after_home" 'managed directory conflict state'
  assert_eq "$before_backing" "$after_backing" 'symlinked directory backing state'
  assert_file_text "${target_home}/.codex" 'not a directory'
  assert_link_target "${target_home}/.claude" "$claude_backing"
  assert_absent "${target_home}/.agents"
}

test_discovers_sources_from_installer_directory() {
  local case_root fixture_root target_home work_dir link_count
  case_root=$(new_case_root) || fail "could not create case root"
  fixture_root="${case_root}/portable-source"
  target_home="${case_root}/home"
  work_dir="${case_root}/unrelated-working-directory"
  mkdir -p -- \
    "${fixture_root}/skills/valid-skill" \
    "${fixture_root}/skills/no-manifest" \
    "$work_dir" \
    || fail "could not create source fixture"
  cp -- "$setup_script" "${fixture_root}/setup.sh" || fail "could not copy setup script"
  cp -- "${repo_root}/RULES.md" "${fixture_root}/RULES.md" || fail "could not copy rules"
  printf '%s\n' '---' 'name: valid-skill' 'description: Fixture.' '---' \
    >"${fixture_root}/skills/valid-skill/SKILL.md"
  printf 'ignored\n' >"${fixture_root}/skills/no-manifest/note.txt"
  printf 'ignored\n' >"${fixture_root}/skills/not-a-directory"

  RUN_OUTPUT=$(cd -- "$work_dir" && "${fixture_root}/setup.sh" --target-home "$target_home" 2>&1)
  RUN_STATUS=$?
  assert_status 0
  assert_link_target "${target_home}/.codex/AGENTS.md" "${fixture_root}/RULES.md"
  assert_link_target "${target_home}/.claude/CLAUDE.md" "${fixture_root}/RULES.md"
  assert_link_target \
    "${target_home}/.agents/skills/valid-skill" \
    "${fixture_root}/skills/valid-skill"
  assert_link_target \
    "${target_home}/.claude/skills/valid-skill" \
    "${fixture_root}/skills/valid-skill"
  assert_absent "${target_home}/.agents/skills/no-manifest"
  assert_absent "${target_home}/.claude/skills/no-manifest"
  assert_absent "${target_home}/.agents/skills/not-a-directory"
  link_count=$(find "$target_home" -type l -print | awk 'END { print NR + 0 }')
  assert_eq 4 "$link_count" 'fixture link count'
}

test_rejects_source_without_valid_skills() {
  local case_root fixture_root target_home
  case_root=$(new_case_root) || fail "could not create case root"
  fixture_root="${case_root}/source"
  target_home="${case_root}/home"
  mkdir -p -- "${fixture_root}/skills/invalid" || fail "could not create source fixture"
  cp -- "$setup_script" "${fixture_root}/setup.sh" || fail "could not copy setup script"
  cp -- "${repo_root}/RULES.md" "${fixture_root}/RULES.md" || fail "could not copy rules"

  capture "${fixture_root}/setup.sh" --target-home "$target_home"
  assert_status 1
  assert_output_contains 'no valid skills found'
  assert_absent "$target_home"
}

test_detects_path_appearing_after_preflight() {
  local case_root target_home fake_bin raced_target link_count
  case_root=$(new_case_root) || fail "could not create case root"
  target_home="${case_root}/home"
  fake_bin="${case_root}/fake-bin"
  raced_target="${target_home}/.codex/AGENTS.md"
  mkdir -p -- "$target_home" || fail "could not create home"
  write_mkdir_race_wrapper "$fake_bin"

  capture env \
    PATH="${fake_bin}:${PATH}" \
    TEST_REAL_MKDIR="$real_mkdir" \
    TEST_RACE_MARKER="${case_root}/race-fired" \
    TEST_RACE_MODE=appear \
    TEST_RACE_TARGET="$raced_target" \
    TEST_RACE_REPLACEMENT="${case_root}/unused" \
    "$setup_script" --target-home "$target_home"
  assert_status 1
  assert_output_contains "path appeared during setup and was not changed: ${raced_target}"
  assert_file_text "$raced_target" 'appeared during setup'
  link_count=$(find "$target_home" -type l -print | awk 'END { print NR + 0 }')
  assert_eq 0 "$link_count" 'links after appearance race'
}

test_detects_link_changing_after_preflight() {
  local case_root target_home fake_bin raced_target replacement link_count
  case_root=$(new_case_root) || fail "could not create case root"
  target_home="${case_root}/home"
  fake_bin="${case_root}/fake-bin"
  raced_target="${target_home}/.codex/AGENTS.md"
  replacement="${case_root}/replacement"
  mkdir -p -- "${target_home}/.codex" "$replacement" || fail "could not seed race fixture"
  ln -s -- "${repo_root}/RULES.md" "$raced_target" || fail "could not seed correct link"
  write_mkdir_race_wrapper "$fake_bin"

  capture env \
    PATH="${fake_bin}:${PATH}" \
    TEST_REAL_MKDIR="$real_mkdir" \
    TEST_RACE_MARKER="${case_root}/race-fired" \
    TEST_RACE_MODE=replace \
    TEST_RACE_TARGET="$raced_target" \
    TEST_RACE_REPLACEMENT="$replacement" \
    "$setup_script" --target-home "$target_home"
  assert_status 1
  assert_output_contains "link changed during setup: ${raced_target} -> ${replacement}"
  assert_link_target "$raced_target" "$replacement"
  link_count=$(find "$target_home" -type l -print | awk 'END { print NR + 0 }')
  assert_eq 1 "$link_count" 'links after changed-link race'
  assert_absent "${target_home}/.claude/CLAUDE.md"
}

record_result() {
  local name=$1
  local status=$2
  if ((status == 0)); then
    printf 'ok - %s\n' "$name"
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
}

if ((${#skill_names[@]} == 0)); then
  fail "no current skills discovered under ${repo_root}/skills"
fi
if [[ ! -x "$setup_script" ]]; then
  fail "setup script is not executable: ${setup_script}"
fi

CURRENT_TEST='help and argument validation'
(test_help_and_argument_validation)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='target home validation'
(test_target_home_validation)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='dry run makes no writes'
(test_dry_run_makes_no_writes)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='exact first install'
(test_exact_first_install)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='environment routing'
(test_environment_routing)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='target home overrides environment routing'
(test_target_home_overrides_environment_routing)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='idempotent reinstall'
(test_idempotent_reinstall)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='preserves unrelated skills and codex skills'
(test_preserves_unrelated_skills_and_codex_skills)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='completes partial valid install'
(test_completes_partial_valid_install)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='aggregates conflicts without writes'
(test_aggregates_conflicts_without_writes)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='rejects managed directory conflicts without writes'
(test_rejects_managed_directory_conflicts_without_writes)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='discovers sources from installer directory'
(test_discovers_sources_from_installer_directory)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='rejects source without valid skills'
(test_rejects_source_without_valid_skills)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='detects path appearing after preflight'
(test_detects_path_appearing_after_preflight)
record_result "$CURRENT_TEST" "$?"

CURRENT_TEST='detects link changing after preflight'
(test_detects_link_changing_after_preflight)
record_result "$CURRENT_TEST" "$?"

printf '%s setup tests passed; %s failed\n' "$passed" "$failed"
((failed == 0))
