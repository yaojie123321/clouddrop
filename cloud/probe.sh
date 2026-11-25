#!/usr/bin/env bash
# ============================================================
# Cloud capability probe
# Purpose: decide whether a Git-based file bridge is possible
#          from this sandbox back to the local machine.
# Usage:   bash probe.sh
# Output:  a short capability matrix, paste it back to the user.
# ============================================================

set -u

ok()   { printf '  [ OK ] %s\n' "$*"; }
no()   { printf '  [ NO ] %s\n' "$*"; }
info() { printf '  [ .. ] %s\n' "$*"; }
head_() { printf '\n===== %s =====\n' "$*"; }

# ---------- 1. environment ----------
head_ "1. ENVIRONMENT"
info "user    : $(id -un 2>/dev/null || echo unknown)"
info "host    : $(hostname 2>/dev/null || echo unknown)"
info "kernel  : $(uname -srm 2>/dev/null || echo unknown)"
info "shell   : ${SHELL:-unknown}"
info "pwd     : $(pwd)"
info "time    : $(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"

# ---------- 2. toolchain ----------
head_ "2. TOOLCHAIN"
for c in git curl wget python3 tar zip unzip rsync base64 openssl ssh; do
  if p=$(command -v "$c" 2>/dev/null); then
    ok "$c -> $p"
  else
    no "$c"
  fi
done

# ---------- 3. outbound network ----------
head_ "3. OUTBOUND NETWORK  (timeout 8s each)"
probe_url() {
  local name="$1" url="$2"
  local out
  out=$(curl -sS -o /dev/null -m 8 -w '%{http_code} %{time_total}s' "$url" 2>&1)
  if [ -z "$out" ]; then
    no "$name -> no response"
  else
    case "$out" in
      *refused*|*timed\ out*|*resolve*|*Could\ not*|*error*)
        no "$name -> $out" ;;
      000*)
        no "$name -> blocked ($out)" ;;
      2*|3*|4*)
        ok "$name -> HTTP ${out%% *}  (${out##* })" ;;
      *)
        no "$name -> $out" ;;
    esac
  fi
}

probe_url "github.com        " "https://github.com"
probe_url "api.github.com    " "https://api.github.com/zen"
probe_url "codeload.github   " "https://codeload.github.com"
probe_url "gitee.com         " "https://gitee.com"
probe_url "gitlab.com        " "https://gitlab.com"
probe_url "generic (baidu)   " "https://www.baidu.com"

# proxy variables
head_ "3b. PROXY VARIABLES"
found_proxy=0
for v in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY; do
  val=$(eval "printf '%s' \"\${$v:-}\"")
  if [ -n "$val" ]; then
    ok "$v = $val"
    found_proxy=1
  fi
done
[ "$found_proxy" -eq 0 ] && info "none set (direct connection)"

# ---------- 4. real git clone test ----------
head_ "4. REAL GIT CLONE TEST"
TMPD=$(mktemp -d 2>/dev/null || echo /tmp/probe.$$)
mkdir -p "$TMPD"
run_to() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}
export GIT_TERMINAL_PROMPT=0
if command -v git >/dev/null 2>&1; then
  if run_to 25 git clone --depth 1 --quiet https://github.com/octocat/Hello-World.git "$TMPD/hw" 2>"$TMPD/err"; then
    ok "clone over HTTPS works (github anonymous)"
  else
    no "clone failed: $(tr '\n' ' ' < "$TMPD/err" 2>/dev/null | cut -c1-160)"
  fi
else
  no "git not installed, skip"
fi
rm -rf "$TMPD" 2>/dev/null

# ---------- 5. egress ip ----------
head_ "5. EGRESS IP"
ip_out=$(curl -sS -m 8 https://api.ipify.org 2>/dev/null)
if [ -n "$ip_out" ]; then ok "public ip: $ip_out"; else no "cannot resolve public ip"; fi

# ---------- 6. source directory ----------
head_ "6. SOURCE DIRECTORY"
for d in /home/workdir/artifacts /home/workdir /tmp/artifacts "$HOME/artifacts" "$HOME"; do
  if [ -d "$d" ]; then
    cnt=$(find "$d" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    sz=$(du -sh "$d" 2>/dev/null | cut -f1)
    ok "$d  (${cnt} files at top level, ${sz})"
  else
    info "$d  absent"
  fi
done

if [ -d /home/workdir/artifacts ]; then
  head_ "6b. ARTIFACT LISTING"
  ls -lhA /home/workdir/artifacts 2>/dev/null | head -20
fi

# ---------- 7. write capability ----------
head_ "7. WRITE TEST"
if touch /home/workdir/.probe_write 2>/dev/null; then
  ok "/home/workdir writable"
  rm -f /home/workdir/.probe_write
else
  no "/home/workdir NOT writable"
fi

# ---------- 8. disk ----------
head_ "8. DISK"
df -h /home/workdir 2>/dev/null | tail -2

# ---------- verdict ----------
head_ "VERDICT"
git_ok=0; net_ok=0
command -v git >/dev/null 2>&1 && git_ok=1
curl -sS -o /dev/null -m 6 https://github.com 2>/dev/null && net_ok=1

if [ "$git_ok" -eq 1 ] && [ "$net_ok" -eq 1 ]; then
  printf '  RESULT: git bridge VIABLE (git + outbound network both available)\n'
elif [ "$net_ok" -eq 1 ]; then
  printf '  RESULT: PARTIAL - network ok but git missing (API upload fallback needed)\n'
else
  printf '  RESULT: git bridge NOT viable (no outbound network)\n'
fi
echo
