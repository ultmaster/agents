#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup.sh [--dry-run] [--prune] [--target-home DIRECTORY]

Install this repository's rules and skills into the current user's Codex and
Claude configuration directories. Existing non-matching paths are never
overwritten. --target-home installs into an alternate home-shaped directory and
is useful for validation.

Renaming or removing a skill leaves a link in the user's skill directories whose
source no longer exists. Those stale links are always reported. --prune removes
them, and only them: a link is pruned only when it points into this repository's
skills directory and that target is gone. Links to any other source are never
touched.
EOF
}

dry_run=false
prune=false
target_home=''
target_home_set=false
while (($#)); do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --prune) prune=true; shift ;;
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

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
rules_source="${repo_root}/RULES.md"
skills_source="${repo_root}/skills"
if "$target_home_set"; then
  user_home=$target_home
  codex_root="${user_home}/.codex"
  claude_root="${user_home}/.claude"
else
  user_home=${HOME:?setup.sh: HOME is not set}
  codex_root=${CODEX_HOME:-"${user_home}/.codex"}
  claude_root=${CLAUDE_CONFIG_DIR:-"${user_home}/.claude"}
fi
codex_skills_root="${user_home}/.agents/skills"
claude_skills_root="${claude_root}/skills"

die() {
  printf 'setup.sh: %s\n' "$*" >&2
  exit 1
}

for absolute_path in "$user_home" "$codex_root" "$claude_root"; do
  [[ "$absolute_path" == /* ]] || die "expected an absolute path: ${absolute_path}"
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
  "${user_home}/.agents"
  "$codex_skills_root"
  "$claude_skills_root"
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
((skill_count > 0)) || die "no valid skills found under ${skills_source}"

conflicts=0
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

for index in "${!link_sources[@]}"; do
  source_path=${link_sources[$index]}
  target_path=${link_targets[$index]}
  if [[ -L "$target_path" ]]; then
    current_target=$(readlink "$target_path")
    if [[ "$current_target" != "$source_path" ]]; then
      printf 'setup.sh: conflict: %s -> %s (expected %s)\n' \
        "$target_path" "$current_target" "$source_path" >&2
      conflicts=$((conflicts + 1))
    fi
  elif [[ -e "$target_path" ]]; then
    printf 'setup.sh: conflict: path already exists and is not this setup link: %s\n' \
      "$target_path" >&2
    conflicts=$((conflicts + 1))
  fi
done

# A renamed or removed skill leaves behind a link whose source no longer exists.
# Only a link pointing into this repository's skills directory is eligible: a
# link to any other source belongs to the user, however broken it looks.
stale_links=()
for skills_root in "$codex_skills_root" "$claude_skills_root"; do
  [[ -d "$skills_root" && ! -L "$skills_root" ]] || continue
  for existing_link in "$skills_root"/*; do
    [[ -L "$existing_link" ]] || continue
    link_target=$(readlink "$existing_link")
    [[ "$link_target" == "${skills_source}/"* ]] || continue
    [[ -e "$link_target" ]] && continue
    stale_links+=("$existing_link")
  done
done

if ! "$prune"; then
  for stale_link in "${stale_links[@]}"; do
    printf 'setup.sh: stale link: %s -> %s (rerun with --prune to remove)\n' \
      "$stale_link" "$(readlink "$stale_link")" >&2
  done
fi

((conflicts == 0)) || die "found ${conflicts} conflict(s); no links were changed"

if "$dry_run"; then
  if "$prune"; then
    for stale_link in "${stale_links[@]}"; do
      printf 'would prune %s -> %s\n' "$stale_link" "$(readlink "$stale_link")"
    done
  fi
  for index in "${!link_sources[@]}"; do
    if [[ -L "${link_targets[$index]}" ]]; then
      printf 'already linked %s -> %s\n' "${link_targets[$index]}" "${link_sources[$index]}"
    else
      printf 'would link %s -> %s\n' "${link_targets[$index]}" "${link_sources[$index]}"
    fi
  done
  exit 0
fi

if "$prune"; then
  for stale_link in "${stale_links[@]}"; do
    # Re-check immediately before removing: the link must still be a symlink
    # into this repository whose target is still missing.
    [[ -L "$stale_link" ]] || die "stale link vanished during setup: ${stale_link}"
    link_target=$(readlink "$stale_link")
    [[ "$link_target" == "${skills_source}/"* && ! -e "$link_target" ]] ||
      die "stale link changed during setup: ${stale_link} -> ${link_target}"
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
