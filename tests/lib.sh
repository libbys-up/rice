# Shared helpers for tests/run.sh and tests/bench.sh. Sourced, not
# executed -- callers set HERE and MANIFEST before sourcing this.

resolve_ricehome() {
  RICEHOME="${RICEHOME:-$(cd "$HERE/.." && pwd)}"
  export RICEHOME
}

resolve_rice() {
  RICE="$(command -v rice || echo "$HOME/.cpm/bin/rice")"
}

# --- manifest lookup: prints STATUS (or nothing) then the reason, for a
# given relative path, by grepping the manifest rather than loading it into
# an associative array (keeps this working under macOS's stock bash 3.2).
manifest_status() {
  local rel="$1"
  local line
  line="$(grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$' | awk -v p="$rel" '$1==p {print; exit}')"
  [ -n "$line" ] && echo "$line" | awk '{print $2}'
}
manifest_reason() {
  local rel="$1"
  grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$' | awk -v p="$rel" '$1==p {$1="";$2=""; print; exit}' | sed 's/^ *//'
}

# Callers populate a global FILTERS array from their own positional args
# before calling this. The loop variable is deliberately not `f` (or any
# name a caller's own enclosing `while read ... <name>` loop might reuse)
# -- bash's `for` doesn't scope its variable to the function, so reusing
# the caller's own loop variable name here would silently clobber it for
# the rest of that iteration once this returns.
matches_filter() {
  local rel="$1"
  [ "${#FILTERS[@]}" -eq 0 ] && return 0
  local flt
  for flt in "${FILTERS[@]}"; do
    case "$rel" in *"$flt"*) return 0 ;; esac
  done
  return 1
}
