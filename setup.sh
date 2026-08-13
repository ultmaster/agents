#!/usr/bin/env bash

set -euo pipefail

readonly manifest_header='# setup.sh manifest; lists the links this installer created'

usage() {
  cat <<'EOF'
Usage: setup.sh [--dry-run] [--prune | --uninstall] [--target-home DIRECTORY]

Install this repository's rules, skills, and subagents into the current user's
Codex and Claude configuration directories. Existing non-matching paths are
never overwritten. --target-home installs into an alternate home-shaped
directory and is useful for validation.

Each install records the links it created in a manifest inside the agents
directory. A later run reads that manifest, so it still recognizes its own
links after this checkout is renamed or moved. A link this installer did not
create is never touched, however broken it looks.

Renaming a skill or subagent, removing one, or moving this checkout leaves a
link whose source no longer exists. Those stale links are always reported.
--prune removes them, and only them: a link is pruned only when the manifest
records it or it points into this repository's skills or subagents directory,
and its target is gone. A stale link occupying a path this run wants blocks the
install until --prune is given.

--uninstall removes every link this installer owns and then the manifest,
leaving directories and unrelated links in place. Run it before deleting this
checkout, since it needs the checkout to know what it installed.

Environment (ignored when --target-home is given):
  HOME               Home directory used for discovery
  CODEX_HOME         Codex configuration directory (default ~/.codex)
  CLAUDE_CONFIG_DIR  Claude configuration directory (default ~/.claude)
  AGENTS_HOME        Shared agents directory holding skills (default ~/.agents)

CODEX_HOME moves the Codex rules file and the Codex subagent definitions, which
Codex discovers only under its own configuration directory. Skills install under
AGENTS_HOME because ~/.agents/skills is a shared discovery path rather than
Codex state, and ~/.codex/skills is never written to at all.
EOF
}

die() {
  printf 'setup.sh: %s\n' "$*" >&2
  exit 1
}

dry_run=false
prune=false
uninstall=false
target_home=''
target_home_set=false
while (($#)); do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --prune) prune=true; shift ;;
    --uninstall) uninstall=true; shift ;;
    --target-home)
      [[ "$#" -ge 2 ]] || { usage >&2; exit 2; }
      target_home=$2
      [[ -n "$target_home" ]] || { printf 'setup.sh: --target-home must not be empty\n' >&2; exit 2; }
      target_home_set=true
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if "$prune" && "$uninstall"; then
  printf 'setup.sh: --prune and --uninstall cannot be combined\n' >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
rules_source="${repo_root}/RULES.md"
skills_source="${repo_root}/skills"
subagents_source="${repo_root}/subagents"
if "$target_home_set"; then
  user_home=$target_home
  codex_root="${user_home}/.codex"
  claude_root="${user_home}/.claude"
  agents_root="${user_home}/.agents"
else
  user_home=${HOME:?setup.sh: HOME is not set}
  codex_root=${CODEX_HOME:-"${user_home}/.codex"}
  claude_root=${CLAUDE_CONFIG_DIR:-"${user_home}/.claude"}
  agents_root=${AGENTS_HOME:-"${user_home}/.agents"}
fi
codex_skills_root="${agents_root}/skills"
claude_skills_root="${claude_root}/skills"
codex_agents_root="${codex_root}/agents"
claude_agents_root="${claude_root}/agents"
manifest_file="${agents_root}/setup-manifest"

for absolute_path in "$user_home" "$codex_root" "$claude_root" "$agents_root"; do
  [[ "$absolute_path" == /* ]] || die "expected an absolute path: ${absolute_path}"
done
# The manifest is a tab-separated record, so a managed path carrying a tab or a
# newline could not be read back unambiguously.
for managed_path in "$repo_root" "$codex_root" "$claude_root" "$agents_root"; do
  case "$managed_path" in
    *$'\t'* | *$'\n'*) die "managed paths must not contain tabs or newlines: ${managed_path}" ;;
  esac
done
if "$target_home_set" && [[ -L "$user_home" ]]; then
  die "--target-home must not be a symlink: ${user_home}"
fi
if [[ -e "$user_home" && ! -d "$user_home" ]]; then
  die "home path is not a directory: ${user_home}"
fi
[[ -f "$rules_source" ]] || die "missing source file: ${rules_source}"
[[ -d "$skills_source" ]] || die "missing source directory: ${skills_source}"

declare -a required_directories=(
  "$codex_root"
  "$claude_root"
  "$agents_root"
  "$codex_skills_root"
  "$claude_skills_root"
  "$codex_agents_root"
  "$claude_agents_root"
)
declare -a link_sources=("$rules_source" "$rules_source")
declare -a link_targets=(
  "${codex_root}/AGENTS.md"
  "${claude_root}/CLAUDE.md"
)

skill_count=0
shopt -s nullglob
for skill_source in "${skills_source}"/*; do
  [[ -d "$skill_source" && -f "${skill_source}/SKILL.md" ]] || continue
  skill_name=${skill_source##*/}
  link_sources+=("$skill_source" "$skill_source")
  link_targets+=(
    "${codex_skills_root}/${skill_name}"
    "${claude_skills_root}/${skill_name}"
  )
  skill_count=$((skill_count + 1))
done
if ! "$uninstall"; then
  ((skill_count > 0)) || die "no valid skills found under ${skills_source}"
fi

# A subagent directory owns one logical role in each harness's native format.
# Each definition is linked on its own, so a role defined for one harness only
# installs there rather than blocking the other.
for subagent_source in "${subagents_source}"/*; do
  [[ -d "$subagent_source" ]] || continue
  subagent_name=${subagent_source##*/}
  if [[ -f "${subagent_source}/${subagent_name}.md" ]]; then
    link_sources+=("${subagent_source}/${subagent_name}.md")
    link_targets+=("${claude_agents_root}/${subagent_name}.md")
  fi
  if [[ -f "${subagent_source}/${subagent_name}.toml" ]]; then
    link_sources+=("${subagent_source}/${subagent_name}.toml")
    link_targets+=("${codex_agents_root}/${subagent_name}.toml")
  fi
done

# The manifest is how a later run recognizes its own links after this checkout
# moves: the link value no longer points anywhere, and without a record there
# would be nothing left to distinguish it from a link the user made.
declare -A manifest_source=()
manifest_is_ours=false
if [[ -f "$manifest_file" && ! -L "$manifest_file" ]]; then
  manifest_first_line=''
  IFS= read -r manifest_first_line <"$manifest_file" || true
  if [[ "$manifest_first_line" == "$manifest_header" ]]; then
    manifest_is_ours=true
    while IFS=$'\t' read -r manifest_target manifest_link || [[ -n "$manifest_target" ]]; do
      [[ -n "$manifest_target" && "$manifest_target" != '#'* && -n "$manifest_link" ]] || continue
      manifest_source["$manifest_target"]=$manifest_link
    done <"$manifest_file"
  fi
fi

# Ownership is not licence to remove: only a link whose target no longer exists
# is ever pruned or replaced. A link pointing at a live path the user chose
# stays a conflict.
link_is_owned() {
  local link_path=$1 link_value=$2
  [[ "$link_value" == "${skills_source}/"* ]] && return 0
  [[ "$link_value" == "${subagents_source}/"* ]] && return 0
  [[ -n "${manifest_source["$link_path"]-}" && "${manifest_source["$link_path"]}" == "$link_value" ]] && return 0
  return 1
}

declare -A stale_seen=()
declare -a stale_links=()
add_stale() {
  [[ -z "${stale_seen["$1"]-}" ]] || return 0
  stale_seen["$1"]=1
  stale_links+=("$1")
}

# Classify every path this run wants before writing anything.
conflicts=0
blocking_stale=0
declare -a plan_state=()
for index in "${!link_sources[@]}"; do
  source_path=${link_sources[$index]}
  target_path=${link_targets[$index]}
  if [[ -L "$target_path" ]]; then
    current_target=$(readlink "$target_path")
    if [[ "$current_target" == "$source_path" ]]; then
      plan_state+=(linked)
    elif [[ ! -e "$target_path" ]] && link_is_owned "$target_path" "$current_target"; then
      plan_state+=(replace)
      add_stale "$target_path"
      blocking_stale=$((blocking_stale + 1))
    else
      plan_state+=(conflict)
      printf 'setup.sh: conflict: %s -> %s (expected %s)\n' \
        "$target_path" "$current_target" "$source_path" >&2
      conflicts=$((conflicts + 1))
    fi
  elif [[ -e "$target_path" ]]; then
    plan_state+=(conflict)
    printf 'setup.sh: conflict: path already exists and is not this setup link: %s\n' \
      "$target_path" >&2
    conflicts=$((conflicts + 1))
  else
    plan_state+=(create)
  fi
done

# A renamed or removed skill or subagent leaves behind a link whose source no
# longer exists. Only a link this installer owns is eligible: a link to any
# other source belongs to the user, however broken it looks.
for discovery_root in \
  "$codex_skills_root" "$claude_skills_root" \
  "$codex_agents_root" "$claude_agents_root"; do
  [[ -d "$discovery_root" && ! -L "$discovery_root" ]] || continue
  for existing_link in "$discovery_root"/*; do
    [[ -L "$existing_link" ]] || continue
    [[ -e "$existing_link" ]] && continue
    link_target=$(readlink "$existing_link")
    link_is_owned "$existing_link" "$link_target" || continue
    add_stale "$existing_link"
  done
done

if "$uninstall"; then
  declare -A remove_seen=()
  declare -a remove_targets=()
  queue_removal() {
    [[ -z "${remove_seen["$1"]-}" ]] || return 0
    remove_seen["$1"]=1
    remove_targets+=("$1")
  }
  for index in "${!link_sources[@]}"; do
    case "${plan_state[$index]}" in
      linked | replace) queue_removal "${link_targets[$index]}" ;;
    esac
  done
  for manifest_target in "${!manifest_source[@]}"; do
    [[ -L "$manifest_target" ]] || continue
    [[ "$(readlink "$manifest_target")" == "${manifest_source["$manifest_target"]}" ]] || continue
    queue_removal "$manifest_target"
  done
  for stale_link in "${stale_links[@]}"; do
    queue_removal "$stale_link"
  done

  if "$dry_run"; then
    for remove_target in "${remove_targets[@]}"; do
      printf 'would remove %s -> %s\n' "$remove_target" "$(readlink "$remove_target")"
    done
    "$manifest_is_ours" && printf 'would remove %s\n' "$manifest_file"
    printf 'would uninstall %s link(s)\n' "${#remove_targets[@]}"
    exit 0
  fi

  removed=0
  for remove_target in "${remove_targets[@]}"; do
    # Re-check immediately before removing: it must still be the same link.
    [[ -L "$remove_target" ]] || die "link vanished during uninstall: ${remove_target}"
    remove_value=$(readlink "$remove_target")
    rm -- "$remove_target"
    printf 'removed %s -> %s\n' "$remove_target" "$remove_value"
    removed=$((removed + 1))
  done
  if "$manifest_is_ours"; then
    rm -- "$manifest_file"
    printf 'removed %s\n' "$manifest_file"
  fi
  printf 'uninstalled %s link(s)\n' "$removed"
  exit 0
fi

for destination_dir in "${required_directories[@]}"; do
  if [[ -L "$destination_dir" ]]; then
    printf 'setup.sh: conflict: managed directory path must not be a symlink: %s\n' \
      "$destination_dir" >&2
    conflicts=$((conflicts + 1))
  elif [[ -e "$destination_dir" && ! -d "$destination_dir" ]]; then
    printf 'setup.sh: conflict: directory path is not a directory: %s\n' "$destination_dir" >&2
    conflicts=$((conflicts + 1))
  fi
done

if [[ -L "$manifest_file" ]] || { [[ -e "$manifest_file" ]] && ! "$manifest_is_ours"; }; then
  printf 'setup.sh: conflict: path already exists and is not this setup manifest: %s\n' \
    "$manifest_file" >&2
  conflicts=$((conflicts + 1))
fi

if ! "$prune"; then
  for stale_link in "${stale_links[@]}"; do
    printf 'setup.sh: stale link: %s -> %s (rerun with --prune to remove)\n' \
      "$stale_link" "$(readlink "$stale_link")" >&2
  done
fi

((conflicts == 0)) || die "found ${conflicts} conflict(s); no links were changed"
if ((blocking_stale > 0)) && ! "$prune"; then
  die "found ${blocking_stale} stale link(s) on paths this install needs; rerun with --prune"
fi

if "$dry_run"; then
  if "$prune"; then
    for stale_link in "${stale_links[@]}"; do
      printf 'would prune %s -> %s\n' "$stale_link" "$(readlink "$stale_link")"
    done
  fi
  for index in "${!link_sources[@]}"; do
    if [[ "${plan_state[$index]}" == linked ]]; then
      printf 'already linked %s -> %s\n' "${link_targets[$index]}" "${link_sources[$index]}"
    else
      printf 'would link %s -> %s\n' "${link_targets[$index]}" "${link_sources[$index]}"
    fi
  done
  printf 'would record %s\n' "$manifest_file"
  exit 0
fi

if "$prune"; then
  for stale_link in "${stale_links[@]}"; do
    # Re-check immediately before removing: the link must still be a symlink
    # this installer owns whose target is still missing.
    [[ -L "$stale_link" ]] || die "stale link vanished during setup: ${stale_link}"
    link_target=$(readlink "$stale_link")
    if [[ -e "$stale_link" ]] || ! link_is_owned "$stale_link" "$link_target"; then
      die "stale link changed during setup: ${stale_link} -> ${link_target}"
    fi
    rm -- "$stale_link"
    printf 'pruned %s -> %s\n' "$stale_link" "$link_target"
  done
fi

for destination_dir in "${required_directories[@]}"; do
  mkdir -p "$destination_dir"
done

for index in "${!link_sources[@]}"; do
  source_path=${link_sources[$index]}
  target_path=${link_targets[$index]}
  if [[ -L "$target_path" ]]; then
    current_target=$(readlink "$target_path")
    if [[ "$current_target" == "$source_path" ]]; then
      printf 'already linked %s -> %s\n' "$target_path" "$source_path"
    else
      die "link changed during setup: ${target_path} -> ${current_target} (expected ${source_path})"
    fi
  elif [[ -e "$target_path" ]]; then
    die "path appeared during setup and was not changed: ${target_path}"
  else
    ln -s "$source_path" "$target_path"
    printf 'linked %s -> %s\n' "$target_path" "$source_path"
  fi
done

manifest_temp="${manifest_file}.${$}.tmp"
{
  printf '%s\n' "$manifest_header"
  for index in "${!link_sources[@]}"; do
    printf '%s\t%s\n' "${link_targets[$index]}" "${link_sources[$index]}"
  done
} >"$manifest_temp"
mv -- "$manifest_temp" "$manifest_file"
printf 'recorded %s\n' "$manifest_file"
