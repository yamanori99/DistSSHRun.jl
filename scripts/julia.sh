# Sourced by the gate scripts. Sets JULIA and JULIA_BIN to Julia 1.13.
# ROOT must be set. Does not install. No fixed juliaup path.
# shellcheck disable=SC2148
use_julia_1_13() {
  JULIA=()
  JULIA_BIN=""
  if command -v julia >/dev/null 2>&1 && julia +1.13 --startup-file=no -e 'exit(0)' >/dev/null 2>&1; then
    JULIA=(julia +1.13)
  elif command -v julia >/dev/null 2>&1 && julia --startup-file=no -e 'exit(VERSION>=v"1.13" && VERSION<v"1.14" ? 0 : 1)' >/dev/null 2>&1; then
    JULIA=(julia)
  else
    echo "Julia 1.13 is not on PATH" >&2
    return 1
  fi
  JULIA_BIN="$("${JULIA[@]}" --startup-file=no -e 'print(joinpath(Sys.BINDIR, "julia"))')"
  if [[ ! -x "${JULIA_BIN}" ]]; then
    echo "Julia 1.13 binary is missing" >&2
    return 1
  fi
}
