#!/bin/sh
# gpu-probe-envtest — run a probe mode inside ANOTHER UNIT'S environment.
#
# Why this exists: a card can survive every workload you run from your own shell
# and die the moment the *deployed service* runs the same workload, because the
# service hands the binary a different userspace — LD_PRELOAD, LD_LIBRARY_PATH
# order, HOME, uid, sandboxing. On the Z240 that difference is the whole mystery:
# a GTX 1060 that passes 8 minutes pinned at its power cap moving verified data
# dies ~6 s into FahCore_28. So run the *identical* healthy workload with the
# service's exact Environment=/User=/Group=/PrivateTmp=/ProtectHome=, and let the
# verdict say whether the environment or the silicon is responsible.
#
# The environment is READ FROM THE LIVE UNIT (`systemctl show`), never copied into
# this repo, so the test cannot drift from what is actually deployed.
#
#   gpu-probe-envtest --unit fah-client --seconds 240 -- continuous --seconds 240
#   gpu-probe-envtest --unit fah-client --extra-ld auto -- mixed --seconds 120
#   gpu-probe-envtest --unit some-svc --dry-run -- ctx --seconds 5
#
# Everything after `--` goes to probe.py verbatim. `--extra-ld auto` puts the
# newest Folding@home OpenMM core directory first on LD_LIBRARY_PATH (its own
# CUDA 11.8-era libcufft/libnvrtc/libOpenMMCUDA), which is what the deployed core
# actually resolves against a CUDA 13 driver.
#
# Caveats worth knowing: unit Environment= values are split on whitespace, so a
# value containing a literal space needs the quoting that systemd emits — fine for
# every path-based variable a GPU service uses, not a general systemd parser. And
# it needs `sudo -n systemd-run`: a system transient unit is the only way to get
# the same User=/sandbox= as the unit under test.
set -eu

PROBE=${GPU_PROBE_PY:-${GPU_PROBE_HOME:+$GPU_PROBE_HOME/probe.py}}
PY=$(command -v python3 || true)
UNIT=
SECS=120
EXTRA_LD=
DRY=0
RUN=
CWD=
EXTRA_ENV=""

while [ $# -gt 0 ]; do
  case "$1" in
    --unit) UNIT=$2; shift 2;;
    --seconds) SECS=$2; shift 2;;
    --extra-ld) EXTRA_LD=$2; shift 2;;
    --run) RUN=$2; shift 2;;
    --cwd) CWD=$2; shift 2;;
    --setenv) EXTRA_ENV="$EXTRA_ENV --setenv=$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    --) shift; break;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$UNIT" ] || { echo "needs --unit NAME" >&2; exit 2; }
if [ -z "$RUN" ]; then
  [ $# -gt 0 ] || { echo "needs command args after --  (e.g. -- continuous --seconds 240)" >&2; exit 2; }
  [ -n "$PY" ] || { echo "python3 not on PATH — run me through gpu-probe's wrappers" >&2; exit 3; }
  [ -n "$PROBE" ] && [ -r "$PROBE" ] || { echo "probe.py not found (GPU_PROBE_PY / GPU_PROBE_HOME)" >&2; exit 3; }
fi

# POSIX sh has no arrays, so the positional list can only hold one dynamic set at a
# time: keep the command args as a string (they are simple tokens — flags and
# paths), and build the systemd-run argument list into "$@" below.
CMD_ARGS="$*"

val() { timeout 20 systemctl show "$UNIT" -p "$1" --value 2>/dev/null; }

ENVLINE=$(val Environment)
UNITUSER=$(val User); UNITGROUP=$(val Group); SUPP=$(val SupplementaryGroups)
PTMP=$(val PrivateTmp); PHOME=$(val ProtectHome); WORKDIR=$(val WorkingDirectory)
STATED=$(val StateDirectory); CACHED=$(val CacheDirectory)

[ -n "$ENVLINE" ] || { echo "unit $UNIT declares no Environment= — nothing to replicate" >&2; exit 2; }

if [ "$EXTRA_LD" = auto ]; then
  EXTRA_LD=$(ls -d /var/lib/fah-client/cores/openmm-core-*/centos-*/*/fahcore-28-*-release-*/ 2>/dev/null | sort | tail -1)
  EXTRA_LD=${EXTRA_LD%/}
  [ -n "$EXTRA_LD" ] || { echo "--extra-ld auto found no openmm-core-28 on this host" >&2; exit 2; }
fi

# --- assemble the transient unit so it matches the one under test -------------
set -- --wait --collect --pipe --quiet
set -- "$@" --property=Type=oneshot
set -- "$@" --property="TimeoutStartSec=$((SECS + 240))"
[ -n "$UNITUSER" ] && set -- "$@" --property="User=$UNITUSER"
[ -n "$UNITGROUP" ] && set -- "$@" --property="Group=$UNITGROUP"
for g in $SUPP; do set -- "$@" --property="SupplementaryGroups=$g"; done
[ "$PTMP" = yes ] && set -- "$@" --property=PrivateTmp=yes
[ "$PHOME" = yes ] && set -- "$@" --property=ProtectHome=yes
# --cwd replaces the unit's WorkingDirectory rather than adding to it: the point of
# --cwd is usually "run the deployed binary against a COPY of its data", so inheriting
# the real directory would defeat the isolation.
if [ -n "$CWD" ]; then set -- "$@" --property="WorkingDirectory=$CWD"
elif [ -n "$WORKDIR" ]; then set -- "$@" --property="WorkingDirectory=$WORKDIR"; fi
[ -n "$STATED" ] && set -- "$@" --property="StateDirectory=$STATED"
[ -n "$CACHED" ] && set -- "$@" --property="CacheDirectory=$CACHED"

# The unit's own environment, verbatim — except LD_LIBRARY_PATH, which gets the
# core's directory prepended when asked (that is the order the core really sees).
for kv in $ENVLINE; do
  case "$kv" in
    LD_LIBRARY_PATH=*) [ -n "$EXTRA_LD" ] && continue
      set -- "$@" --setenv="$kv";;
    *) set -- "$@" --setenv="$kv";;
  esac
done
if [ -n "$EXTRA_LD" ]; then
  base=$(printf '%s\n' $ENVLINE | sed -n 's/^LD_LIBRARY_PATH=//p')
  set -- "$@" --setenv="LD_LIBRARY_PATH=$EXTRA_LD${base:+:$base}"
fi

# The caller's overrides last: systemd keeps the LAST Environment= entry for a key,
# so this is how you A/B a single knob (CUDA_MODULE_LOADING=EAGER, say) against the
# deployed environment without editing the service.
for kv in $EXTRA_ENV; do set -- "$@" "$kv"; done

if [ -n "$RUN" ]; then
  echo "envtest: unit=$UNIT user=${UNITUSER:-root?} sandbox=${PTMP:-?}/${PHOME:-?} cwd=${CWD:-$WORKDIR}"
  echo "envtest: running $RUN $CMD_ARGS"
  if [ "$DRY" = 1 ]; then
    printf 'would run: sudo -n systemd-run'; printf ' %s' "$@"
    printf -- ' -- sh -c "%s %s"\n' "$RUN" "$CMD_ARGS"
    exit 0
  fi
  timeout $((SECS + 180)) sudo -n systemd-run "$@" -- sh -c '"$0" $1' "$RUN" "$CMD_ARGS"
else
  echo "envtest: unit=$UNIT user=${UNITUSER:-root?} sandbox=${PTMP:-?}/${PHOME:-?} ld_first=${EXTRA_LD:-unit-default}"
  echo "envtest: probe args: $CMD_ARGS"
  if [ "$DRY" = 1 ]; then
    printf 'would run: sudo -n systemd-run'; printf ' %s' "$@"
    printf -- ' -- sh -c "%s %s %s"\n' "$PY" "$PROBE" "$CMD_ARGS"
    exit 0
  fi
  # `sh -c` with the values as positional parameters: avoids re-quoting, and keeps
  # absolute paths (the unit's own PATH is often a minimal one with no python).
  timeout $((SECS + 180)) sudo -n systemd-run "$@" -- sh -c '"$0" "$1" $2' "$PY" "$PROBE" "$CMD_ARGS"
fi
