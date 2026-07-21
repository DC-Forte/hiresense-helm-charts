#!/usr/bin/env bash
# Check charts/monitoring/Chart.yaml dependencies against upstream repos.
# Usage:
#   ./scripts/check-chart-updates.sh          # check + interactive picker for which to bump
#   ./scripts/check-chart-updates.sh -c       # report only, no prompt (CI-friendly)
#   ./scripts/check-chart-updates.sh -a       # bump every outdated dep, no prompt

set -euo pipefail

readonly CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/charts/monitoring"
readonly CHART_FILE="${CHART_DIR}/Chart.yaml"
added_aliases=()

usage() {
  echo "Usage: $(basename "$0") [-c|-a]"
  echo "  -c  check only, no prompt (CI-friendly)"
  echo "  -a  bump every outdated dep, no prompt"
  echo "  (no flag) interactive picker"
}

cleanup() {
  local alias
  for alias in "${added_aliases[@]:-}"; do
    [[ -n "$alias" ]] && helm repo remove "$alias" >/dev/null 2>&1 || true
  done
  rm -f "${CHART_FILE}.tmp"
}

tmp_alias() {
  echo "check-tmp-$(echo "$1" | tr -c 'a-zA-Z0-9' '-')"
}

latest_version() {
  local name="$1" repo="$2"
  local alias
  alias=$(tmp_alias "$name")
  added_aliases+=("$alias")
  helm repo add --force-update "$alias" "$repo" >/dev/null
  helm repo update "$alias" >/dev/null
  helm search repo "${alias}/${name}" --versions -o json | jq -r '.[0].version'
  helm repo remove "$alias" >/dev/null
  added_aliases=("${added_aliases[@]/$alias/}")
}

bump_version() {
  local name="$1" new="$2"
  awk -v name="$name" -v new="$new" '
    /^  - name:/ { current = $NF }
    current == name && $1 == "version:" {
      sub(/"[^"]*"/, "\"" new "\"")
      current = ""
    }
    { print }
  ' "$CHART_FILE" > "${CHART_FILE}.tmp" && mv "${CHART_FILE}.tmp" "$CHART_FILE"
  echo "  bumped ${name} -> ${new}"
}

find_outdated() {
  local name version repo status latest
  while IFS=$'\t' read -r name version repo status; do
    [[ -z "$name" || "$name" == "NAME" ]] && continue
    latest=$(latest_version "$name" "$repo")
    if [[ "$latest" != "$version" ]]; then
      echo "OUTDATED  ${name}: ${version} -> ${latest}" >&2
      echo "${name}|${version}|${latest}"
    else
      echo "OK        ${name}: ${version}" >&2
    fi
  done < <(helm dependency list "$CHART_DIR" \
    | awk -F'\t' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3); print $1"\t"$2"\t"$3}')
}

prompt_selection() {
  local -n _outdated=$1
  local i name old new selection idx
  echo >&2
  echo "Select deps to bump:" >&2
  for i in "${!_outdated[@]}"; do
    IFS='|' read -r name old new <<< "${_outdated[$i]}"
    printf "  %d) %-24s %s -> %s\n" "$((i + 1))" "$name" "$old" "$new" >&2
  done
  echo >&2
  read -rp "Enter numbers separated by space (a=all, q/enter=none): " selection

  if [[ -z "$selection" || "$selection" == "q" ]]; then
    return
  elif [[ "$selection" == "a" ]]; then
    printf '%s\n' "${_outdated[@]}"
  else
    for n in $selection; do
      idx=$((n - 1))
      if [[ -n "${_outdated[$idx]:-}" ]]; then
        printf '%s\n' "${_outdated[$idx]}"
      else
        echo "  skipping invalid choice: $n" >&2
      fi
    done
  fi
}

main() {
  local mode="interactive"
  local opt
  while getopts "cah" opt; do
    case "$opt" in
      c) mode="check" ;;
      a) mode="all" ;;
      h) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  trap cleanup EXIT

  echo "Checking dependencies in ${CHART_FILE} ..."
  local outdated=()
  while IFS= read -r line; do
    outdated+=("$line")
  done < <(find_outdated)

  if [[ ${#outdated[@]} -eq 0 ]]; then
    echo "All dependencies up to date."
    exit 0
  fi

  [[ "$mode" == "check" ]] && exit 0

  local picked=()
  if [[ "$mode" == "all" ]]; then
    echo "Bumping all outdated deps in ${CHART_FILE} ..."
    picked=("${outdated[@]}")
  else
    while IFS= read -r line; do
      picked+=("$line")
    done < <(prompt_selection outdated)

    if [[ ${#picked[@]} -eq 0 ]]; then
      echo "No changes made."
      exit 0
    fi
    echo "Bumping selected deps in ${CHART_FILE} ..."
  fi

  local name old new
  for entry in "${picked[@]}"; do
    IFS='|' read -r name old new <<< "$entry"
    bump_version "$name" "$new"
  done
  echo "Run: helm dependency update ${CHART_DIR}"
}

main "$@"
