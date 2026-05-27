#!/bin/bash
# Tests for .claude/hooks/_lib-features.sh — the feature-flag reader library.
#
# Cases:
#   1. feature_enabled returns 0 (enabled) when enabled: true
#   2. feature_enabled returns 1 (disabled) when enabled: false
#   3. feature_enabled returns 0 when key is absent (backward compat)
#   4. feature_enabled returns 0 when features.yaml is missing (no-op)
#   5. feature_get returns the correct value for a nested key
#   6. feature_get returns fallback when key is absent
#   7. feature_get returns fallback when file is missing
#   8. feature_enabled handles False/FALSE/no variants
#   9. features_clear_cache resets state

set -u

LIB_FEATURES_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-features.sh"
LIB_PORTFOLIO_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-portfolio-paths.sh"
LIB_CONFIG_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-read-config.sh"

if [ ! -f "$LIB_FEATURES_SRC" ]; then
  echo "FAIL: _lib-features.sh not found at $LIB_FEATURES_SRC" >&2
  exit 1
fi

RESULTS_FILE=$(mktemp)
echo "0 0" > "$RESULTS_FILE"

pass() {
  echo "  PASS: $1"
  local p f; read -r p f < "$RESULTS_FILE"
  echo "$((p + 1)) $f" > "$RESULTS_FILE"
}
fail() {
  echo "  FAIL: $1"
  local p f; read -r p f < "$RESULTS_FILE"
  echo "$p $((f + 1))" > "$RESULTS_FILE"
}

make_features_file() {
  local dir
  dir=$(mktemp -d)
  dir=$(cd "$dir" && pwd -P)
  cat > "$dir/features.yaml" <<'YAML'
version: 1
aws_diagram:
  enabled: true
admin_app:
  enabled: true
  port: 3000
vector_index:
  enabled: false
  db: chromadb
  index_on_session_start: false
disabled_cap:
  enabled: False
disabled_no:
  enabled: no
YAML
  echo "$dir/features.yaml"
}

# --------------------------------------------------------------------------
echo "Case 1: feature_enabled returns 0 when enabled: true"
# --------------------------------------------------------------------------
(
  source "$LIB_FEATURES_SRC"
  f=$(make_features_file)
  _FEATURES_FILE_CACHE="$f"
  if feature_enabled aws_diagram; then
    pass "case 1"
  else
    fail "case 1 — aws_diagram should be enabled"
  fi
  rm -rf "$(dirname "$f")"
) || fail "case 1 — subshell error"

# --------------------------------------------------------------------------
echo "Case 2: feature_enabled returns 1 when enabled: false"
# --------------------------------------------------------------------------
(
  source "$LIB_FEATURES_SRC"
  f=$(make_features_file)
  _FEATURES_FILE_CACHE="$f"
  if feature_enabled vector_index; then
    fail "case 2 — vector_index should be disabled"
  else
    pass "case 2"
  fi
  rm -rf "$(dirname "$f")"
) || fail "case 2 — subshell error"

# --------------------------------------------------------------------------
echo "Case 3: feature_enabled returns 0 when key is absent"
# --------------------------------------------------------------------------
(
  source "$LIB_FEATURES_SRC"
  f=$(make_features_file)
  _FEATURES_FILE_CACHE="$f"
  if feature_enabled nonexistent_feature; then
    pass "case 3"
  else
    fail "case 3 — absent key should be treated as enabled"
  fi
  rm -rf "$(dirname "$f")"
) || fail "case 3 — subshell error"

# --------------------------------------------------------------------------
echo "Case 4: feature_enabled returns 0 when file is missing"
# --------------------------------------------------------------------------
(
  source "$LIB_FEATURES_SRC"
  _FEATURES_FILE_CACHE="/tmp/does-not-exist-$$-features.yaml"
  if feature_enabled anything; then
    pass "case 4"
  else
    fail "case 4 — missing file should mean all enabled"
  fi
) || fail "case 4 — subshell error"

# --------------------------------------------------------------------------
echo "Case 5: feature_get returns correct nested value"
# --------------------------------------------------------------------------
(
  source "$LIB_FEATURES_SRC"
  f=$(make_features_file)
  _FEATURES_FILE_CACHE="$f"
  val=$(feature_get vector_index db fallback)
  if [ "$val" = "chromadb" ]; then
    pass "case 5"
  else
    fail "case 5 — expected 'chromadb', got '$val'"
  fi
  rm -rf "$(dirname "$f")"
) || fail "case 5 — subshell error"

# --------------------------------------------------------------------------
echo "Case 6: feature_get returns fallback when key absent"
# --------------------------------------------------------------------------
(
  source "$LIB_FEATURES_SRC"
  f=$(make_features_file)
  _FEATURES_FILE_CACHE="$f"
  val=$(feature_get aws_diagram nonexistent_key mydefault)
  if [ "$val" = "mydefault" ]; then
    pass "case 6"
  else
    fail "case 6 — expected 'mydefault', got '$val'"
  fi
  rm -rf "$(dirname "$f")"
) || fail "case 6 — subshell error"

# --------------------------------------------------------------------------
echo "Case 7: feature_get returns fallback when file missing"
# --------------------------------------------------------------------------
(
  source "$LIB_FEATURES_SRC"
  _FEATURES_FILE_CACHE="/tmp/does-not-exist-$$-features.yaml"
  val=$(feature_get anything key fallback_val)
  if [ "$val" = "fallback_val" ]; then
    pass "case 7"
  else
    fail "case 7 — expected 'fallback_val', got '$val'"
  fi
) || fail "case 7 — subshell error"

# --------------------------------------------------------------------------
echo "Case 8: feature_enabled handles False/no variants"
# --------------------------------------------------------------------------
(
  source "$LIB_FEATURES_SRC"
  f=$(make_features_file)
  _FEATURES_FILE_CACHE="$f"
  err=0
  feature_enabled disabled_cap && err=1
  feature_enabled disabled_no && err=$((err + 2))
  if [ "$err" -eq 0 ]; then
    pass "case 8"
  else
    fail "case 8 — False/no should disable (err=$err)"
  fi
  rm -rf "$(dirname "$f")"
) || fail "case 8 — subshell error"

# --------------------------------------------------------------------------
echo "Case 9: features_clear_cache resets state"
# --------------------------------------------------------------------------
(
  source "$LIB_FEATURES_SRC"
  f=$(make_features_file)
  _FEATURES_FILE_CACHE="$f"
  feature_enabled aws_diagram >/dev/null
  features_clear_cache
  if [ -z "$_FEATURES_CACHE" ] && [ -z "$_FEATURES_FILE_CACHE" ]; then
    pass "case 9"
  else
    fail "case 9 — cache not cleared"
  fi
  rm -rf "$(dirname "$f")"
) || fail "case 9 — subshell error"

# --------------------------------------------------------------------------
echo ""
read -r PASS FAIL < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
