#!/bin/bash
# _lib-features.sh — read feature flags from features.yaml
#
# Source this library from any hook or skill that needs to check whether
# a private portfolio feature is enabled or disabled.
#
# Usage:
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-features.sh"
#   feature_enabled aws_diagram && echo "on" || echo "off"
#   db=$(feature_get vector_index db chromadb)
#
# Semantics:
#   - Missing features.yaml         → all features enabled (no-op)
#   - Key absent from features.yaml → enabled (backward compat)
#   - Explicit enabled: false       → disabled
#   - Explicit enabled: true        → enabled
#
# Parsing: yq → python3 yaml → grep. Same graceful-degrade as
# _lib-read-config.sh.

_FEATURES_CACHE=""
_FEATURES_FILE_CACHE=""

# _features_file: resolve the features.yaml path (cached).
_features_file() {
  if [ -n "$_FEATURES_FILE_CACHE" ]; then
    echo "$_FEATURES_FILE_CACHE"
    return 0
  fi
  if command -v portfolio_features_file >/dev/null 2>&1; then
    _FEATURES_FILE_CACHE=$(portfolio_features_file 2>/dev/null)
  else
    local hook_dir
    hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$hook_dir/_lib-portfolio-paths.sh" ]; then
      # shellcheck source=/dev/null
      . "$hook_dir/_lib-read-config.sh" 2>/dev/null
      # shellcheck source=/dev/null
      . "$hook_dir/_lib-portfolio-paths.sh" 2>/dev/null
      _FEATURES_FILE_CACHE=$(portfolio_features_file 2>/dev/null)
    fi
  fi
  echo "${_FEATURES_FILE_CACHE:-}"
}

# _features_read: slurp features.yaml content (cached per-process).
_features_read() {
  if [ -n "$_FEATURES_CACHE" ]; then
    echo "$_FEATURES_CACHE"
    return 0
  fi
  local f
  f=$(_features_file)
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    return 0
  fi
  _FEATURES_CACHE=$(cat "$f" 2>/dev/null)
  echo "$_FEATURES_CACHE"
}

# feature_enabled <name>
#   Returns 0 if the feature is enabled, 1 if explicitly disabled.
#   Missing file or missing key = enabled (exit 0).
feature_enabled() {
  local name="$1"
  [ -z "$name" ] && return 0

  local f
  f=$(_features_file)
  # No file = all enabled.
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    return 0
  fi

  local val=""

  # Try yq first.
  if command -v yq >/dev/null 2>&1; then
    val=$(yq eval ".$name.enabled // \"\"" "$f" 2>/dev/null)
  fi

  # Fallback: python3 + yaml. Values passed via env vars to avoid injection.
  if [ -z "$val" ] && command -v python3 >/dev/null 2>&1; then
    val=$(FEATURES_FILE="$f" FEATURES_KEY="$name" python3 -c "
import yaml, os
try:
    d = yaml.safe_load(open(os.environ['FEATURES_FILE']))
    v = (d or {}).get(os.environ['FEATURES_KEY'], {})
    if isinstance(v, dict):
        print(v.get('enabled', ''))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null)
  fi

  # Fallback: grep for the simplest case.
  if [ -z "$val" ]; then
    local content
    content=$(_features_read)
    if [ -n "$content" ]; then
      val=$(echo "$content" | grep -A1 "^${name}:" | grep "enabled:" | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]')
    fi
  fi

  # Empty / absent = enabled.
  [ -z "$val" ] && return 0
  # Explicit false = disabled.
  case "$val" in
    false|False|FALSE|no|No|NO) return 1 ;;
  esac
  return 0
}

# feature_get <name> <key> [fallback]
#   Returns the value of a per-feature config key.
feature_get() {
  local name="$1"
  local key="$2"
  local fallback="${3:-}"

  local f
  f=$(_features_file)
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    echo "$fallback"
    return 0
  fi

  local val=""

  if command -v yq >/dev/null 2>&1; then
    val=$(yq eval ".$name.$key // \"\"" "$f" 2>/dev/null)
  fi

  if [ -z "$val" ] && command -v python3 >/dev/null 2>&1; then
    val=$(FEATURES_FILE="$f" FEATURES_KEY="$name" FEATURES_SUBKEY="$key" python3 -c "
import yaml, os
try:
    d = yaml.safe_load(open(os.environ['FEATURES_FILE']))
    v = (d or {}).get(os.environ['FEATURES_KEY'], {})
    if isinstance(v, dict):
        r = v.get(os.environ['FEATURES_SUBKEY'], '')
        print('' if r is None else r)
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null)
  fi

  if [ -z "$val" ]; then
    local content
    content=$(_features_read)
    if [ -n "$content" ]; then
      val=$(echo "$content" | grep -A5 "^${name}:" | grep "${key}:" | head -1 | sed "s/.*${key}:[[:space:]]*//" | tr -d '[:space:]')
    fi
  fi

  if [ -z "$val" ]; then
    echo "$fallback"
  else
    echo "$val"
  fi
}

# features_clear_cache: reset per-process caches (for tests).
features_clear_cache() {
  _FEATURES_CACHE=""
  _FEATURES_FILE_CACHE=""
}
