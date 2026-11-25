#!/usr/bin/env bash
# ============================================================
# Push files from the cloud sandbox into a Git repo,
# so the local machine can pull them down.
#
# Required env vars:
#   GIT_REPO   e.g. github.com/yourname/clouddrop   (no scheme, no .git)
#   GIT_TOKEN  personal access token with write access to that repo
#
# Optional:
#   SRC_DIR    default /home/workdir/artifacts
#   BRANCH     default main
#   AWS        any non-empty value sends files to inbox/<host-timestamp>/
#              (default: artifacts/<host-timestamp>/)
#
# Usage:
#   export GIT_REPO=github.com/yourname/clouddrop
#   export GIT_TOKEN=ghp_xxxxx
#   bash push.sh
# ============================================================

set -euo pipefail

SRC_DIR="${SRC_DIR:-/home/workdir/artifacts}"
: "${GIT_REPO:?GIT_REPO not set, e.g. github.com/yourname/clouddrop}"

# local path / file:// is accepted so the whole flow can be rehearsed
# without a real remote (used by the self-test)
IS_LOCAL=0
case "$GIT_REPO" in
  file://*|/*|./*) IS_LOCAL=1 ;;
esac

if [ "$IS_LOCAL" -eq 1 ]; then
  REMOTE_URL="$GIT_REPO"
  AUTH_USER=""
else
  : "${GIT_TOKEN:?GIT_TOKEN not set (needed for https remote)}"
  # host part decides auth user: github uses x-access-token, gitee uses oauth2
  case "$GIT_REPO" in
    *github.com*) AUTH_USER="x-access-token" ;;
    *)            AUTH_USER="oauth2" ;;
  esac
  REMOTE_URL="https://${AUTH_USER}:${GIT_TOKEN}@${GIT_REPO}.git"
fi

TAG="$(hostname 2>/dev/null || echo cloud)-$(date +%Y%m%d-%H%M%S)"
DEST_SUB="${AWS:+inbox}"; DEST_SUB="${DEST_SUB:-artifacts}"

log() { printf '[push] %s\n' "$*"; }
die() { printf '[push][FAIL] %s\n' "$*" >&2; exit 1; }

[ -d "$SRC_DIR" ] || die "source dir not found: $SRC_DIR"
[ -n "$(ls -A "$SRC_DIR" 2>/dev/null)" ] || die "source dir is empty: $SRC_DIR"

git config --global user.email >/dev/null 2>&1 || \
  git config --global user.email "clouddrop@localhost"
git config --global user.name  >/dev/null 2>&1 || \
  git config --global user.name  "clouddrop"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"

# Gitee defaults to master, GitHub to main. Detect instead of guessing.
if [ -z "${BRANCH:-}" ]; then
  DETECTED=$(git ls-remote --symref "$REMOTE_URL" HEAD 2>/dev/null | head -1 \
    | sed -n 's|^ref: refs/heads/\([^[:space:]]*\).*|\1|p')
  BRANCH="${DETECTED:-main}"
  if [ -n "$DETECTED" ]; then
    log "branch not set, detected remote default: $BRANCH"
  else
    log "branch not set and undetectable (empty repo), using: $BRANCH"
  fi
fi

log "cloning $GIT_REPO ($BRANCH)"
if ! git clone --depth 1 --branch "$BRANCH" "$REMOTE_URL" "$REPO" 2>"$WORK/err"; then
  # empty repo (no commit yet) or branch not created: bootstrap it
  log "clone failed, trying bootstrap for a fresh repository"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" remote add origin "$REMOTE_URL"
  git -C "$REPO" checkout -q -b "$BRANCH" 2>/dev/null || true
  if ! git -C "$REPO" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    log "remote branch does not exist yet, will create it"
  else
    cat "$WORK/err" >&2 2>/dev/null || true
    die "clone failed and remote branch exists, check token permission"
  fi
fi

DEST="$REPO/$DEST_SUB/$TAG"
mkdir -p "$DEST"

# A file bridge must be byte-exact. Without this, a Windows client with
# core.autocrlf=true rewrites LF -> CRLF on checkout and silently corrupts
# shell scripts, patch files and some binaries.
if [ ! -f "$REPO/.gitattributes" ]; then
  printf '# CloudDrop: keep bytes exactly as uploaded (no EOL conversion)\n* -text\n' > "$REPO/.gitattributes"
  log "wrote .gitattributes (binary-safe, no CRLF rewriting)"
fi

log "copying $SRC_DIR -> $DEST_SUB/$TAG"
# copy contents, skip VCS dirs and common junk
( cd "$SRC_DIR" && tar cf - \
    --exclude='.git' --exclude='node_modules' --exclude='__pycache__' \
    --exclude='*.pyc' --exclude='.DS_Store' . ) | ( cd "$DEST" && tar xf - )

# refuse oversized payloads early: GitHub rejects single files > 100 MB
BIG=$(find "$DEST" -type f -size +95M 2>/dev/null | head -5)
if [ -n "$BIG" ]; then
  printf '[push][WARN] files larger than 95MB will be rejected by the remote:\n%s\n' "$BIG"
  while IFS= read -r f; do rm -f "$f"; done <<< "$BIG"
  printf '[push][WARN] oversized files were skipped\n'
fi

# manifest: what this batch contains
{
  echo "batch    : $TAG"
  echo "source   : $SRC_DIR"
  echo "host     : $(hostname 2>/dev/null || echo unknown)"
  echo "created  : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "---"
  ( cd "$DEST" && find . -type f 2>/dev/null | sort | while IFS= read -r f; do
      printf '%10s  %s\n' "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" "$f"
    done )
} > "$DEST/_manifest.txt"

COUNT=$(find "$DEST" -type f | wc -l | tr -d ' ')
log "staged $COUNT files"

cd "$REPO"
git add -A
if git diff --cached --quiet; then
  log "no changes to commit (identical payload already present)"
else
  git commit -q -m "clouddrop: $TAG ($COUNT files)"
  log "committed"
fi

log "pushing to origin/$BRANCH"
if ! git push -q origin "$BRANCH" 2>"$WORK/perr"; then
  log "push rejected, retrying after rebase"
  git fetch -q origin "$BRANCH" 2>/dev/null || true
  git rebase -q "origin/$BRANCH" 2>/dev/null || git rebase --abort 2>/dev/null || true
  git push -q origin "$BRANCH" 2>"$WORK/perr2" || {
    cat "$WORK/perr2" >&2 2>/dev/null || true
    die "push failed, check token scope (needs contents:write) and branch protection"
  }
fi

log "DONE  batch=$TAG  files=$COUNT"
echo
echo "Now on your Windows machine, double-click:  G:\\CloudDrop\\pull.cmd"
echo
