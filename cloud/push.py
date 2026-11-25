#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CloudDrop pusher, API edition.

Uploads files from the cloud sandbox into a GitHub repo using the Git Data
API (blobs -> tree -> commit -> ref). Nothing here needs the git binary or
the git wire protocol, so it keeps working on networks where `git clone`
is blocked or unstable but api.github.com is reachable.

Required env:
    GIT_REPO    github.com/<owner>/<repo>     (scheme and .git optional)
    GIT_TOKEN   personal access token with Contents: read+write

Optional env:
    SRC_DIR     default /home/workdir/artifacts
    BRANCH      default: auto-detected, falls back to main
    DEST_SUB    'artifacts' (default) or 'inbox'
    MAX_MB      per-file limit, default 95

Usage:
    export GIT_REPO=github.com/yourname/clouddrop
    export GIT_TOKEN=ghp_xxx
    python3 push.py
"""

import base64
import datetime
import json
import os
import socket
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv", ".cache"}
TIMEOUT = 60


def log(msg):
    print("[push] %s" % msg, flush=True)


def die(msg):
    print("[push][FAIL] %s" % msg, file=sys.stderr, flush=True)
    sys.exit(1)


def call(method, url, token, payload=None, ok_codes=(200, 201, 204)):
    body = None
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", "token %s" % token)
    req.add_header("User-Agent", "CloudDrop")
    req.add_header("Accept", "application/vnd.github+json")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read().decode("utf-8", "replace")
            return resp.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        if e.code in ok_codes:
            try:
                return e.code, (json.loads(raw) if raw.strip() else {})
            except ValueError:
                return e.code, {}
        return e.code, {"_error": raw[:500]}
    except urllib.error.URLError as e:
        return 0, {"_error": "network: %s" % e.reason}
    except socket.timeout:
        return 0, {"_error": "timeout after %ss" % TIMEOUT}


def parse_slug(repo):
    s = repo.strip()
    for p in ("https://", "http://"):
        if s.startswith(p):
            s = s[len(p):]
    if s.endswith(".git"):
        s = s[:-4]
    s = s.rstrip("/")
    if s.startswith("github.com/"):
        s = s[len("github.com/"):]
    parts = s.split("/")
    if len(parts) != 2 or not all(parts):
        die("GIT_REPO must look like github.com/owner/repo, got: %s" % repo)
    return "%s/%s" % (parts[0], parts[1])


def collect(src):
    out = []
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in files:
            if fn.endswith((".pyc", ".DS_Store")):
                continue
            full = os.path.join(root, fn)
            if os.path.islink(full):
                continue
            try:
                size = os.path.getsize(full)
            except OSError:
                continue
            rel = os.path.relpath(full, src).replace(os.sep, "/")
            out.append((rel, full, size))
    out.sort(key=lambda x: x[0])
    return out


def main():
    repo = os.environ.get("GIT_REPO", "").strip()
    token = os.environ.get("GIT_TOKEN", "").strip()
    src = os.environ.get("SRC_DIR", "/home/workdir/artifacts").rstrip("/")
    dest_sub = os.environ.get("DEST_SUB", "artifacts").strip("/") or "artifacts"
    max_mb = float(os.environ.get("MAX_MB", "95"))
    branch = os.environ.get("BRANCH", "").strip()

    if not repo:
        die("GIT_REPO not set")
    if not token:
        die("GIT_TOKEN not set")
    if not os.path.isdir(src):
        die("SRC_DIR not a directory: %s" % src)

    slug = parse_slug(repo)
    host = socket.gethostname() or "cloud"
    tag = "%s-%s" % (host, datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    log("repo    : %s" % slug)
    log("source  : %s" % src)
    log("batch   : %s" % tag)

    files = collect(src)
    if not files:
        die("source directory is empty: %s" % src)

    kept, skipped = [], []
    for rel, full, size in files:
        if size > max_mb * 1024 * 1024:
            skipped.append("%s (%.1f MB)" % (rel, size / 1048576.0))
        else:
            kept.append((rel, full, size))
    if skipped:
        log("WARNING: skipping %d oversized file(s):" % len(skipped))
        for s in skipped[:5]:
            log("   %s" % s)
    if not kept:
        die("no uploadable files left after size filter")

    # ---- resolve branch ----
    if not branch:
        for cand in ("main", "master"):
            st, body = call("GET", "%s/repos/%s/git/ref/heads/%s" % (API, slug, cand), token)
            if st == 200 and body.get("object"):
                branch = cand
                log("branch  : %s (auto-detected)" % branch)
                break
        if not branch:
            branch = "main"
            log("branch  : main (default, remote has no ref yet)")

    # ---- base commit / tree ----
    base_commit = None
    base_tree = None
    st, ref = call("GET", "%s/repos/%s/git/ref/heads/%s" % (API, slug, branch), token)
    if st == 200 and ref.get("object"):
        base_commit = ref["object"]["sha"]
        st2, commit = call("GET", "%s/repos/%s/git/commits/%s" % (API, slug, base_commit), token)
        if st2 == 200 and commit.get("tree"):
            base_tree = commit["tree"]["sha"]
        log("base    : %s" % base_commit[:10])
    else:
        log("base    : empty branch, creating first commit")

    # ---- upload blobs ----
    entries = []
    total = 0
    for idx, (rel, full, size) in enumerate(kept, 1):
        with open(full, "rb") as fh:
            data = base64.b64encode(fh.read()).decode("ascii")
        st, blob = call("POST", "%s/repos/%s/git/blobs" % (API, slug), token,
                        {"content": data, "encoding": "base64"})
        if st not in (200, 201) or not blob.get("sha"):
            die("blob upload failed for %s (HTTP %s): %s" % (rel, st, blob.get("_error", "")[:200]))
        dest = "%s/%s/%s" % (dest_sub, tag, rel)
        entries.append({"path": dest, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        total += size
        log("  [%d/%d] %s (%.0f B)" % (idx, len(kept), rel, size))

    # ---- manifest ----
    lines = [
        "batch    : %s" % tag,
        "source   : %s" % src,
        "host     : %s" % host,
        "created  : %s" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "files    : %d" % len(kept),
        "bytes    : %d" % total,
        "---",
    ]
    for rel, full, size in kept:
        lines.append("%10d  %s" % (size, rel))
    manifest = "\n".join(lines) + "\n"
    st, blob = call("POST", "%s/repos/%s/git/blobs" % (API, slug), token,
                    {"content": base64.b64encode(manifest.encode("utf-8")).decode("ascii"),
                     "encoding": "base64"})
    if st in (200, 201) and blob.get("sha"):
        entries.append({"path": "%s/%s/_manifest.txt" % (dest_sub, tag),
                        "mode": "100644", "type": "blob", "sha": blob["sha"]})

    # ---- tree ----
    tree_payload = {"tree": entries}
    if base_tree:
        tree_payload["base_tree"] = base_tree
    st, tree = call("POST", "%s/repos/%s/git/trees" % (API, slug), token, tree_payload)
    if st not in (200, 201) or not tree.get("sha"):
        die("tree creation failed (HTTP %s): %s" % (st, tree.get("_error", "")[:300]))

    # ---- commit ----
    commit_payload = {"message": "clouddrop: %s (%d files)" % (tag, len(kept)), "tree": tree["sha"]}
    if base_commit:
        commit_payload["parents"] = [base_commit]
    st, commit = call("POST", "%s/repos/%s/git/commits" % (API, slug), token, commit_payload)
    if st not in (200, 201) or not commit.get("sha"):
        die("commit failed (HTTP %s): %s" % (st, commit.get("_error", "")[:300]))
    log("commit  : %s" % commit["sha"][:10])

    # ---- move ref ----
    if base_commit:
        st, body = call("PATCH", "%s/repos/%s/git/refs/heads/%s" % (API, slug, branch), token,
                        {"sha": commit["sha"], "force": False})
    else:
        st, body = call("POST", "%s/repos/%s/git/refs" % (API, slug), token,
                        {"ref": "refs/heads/%s" % branch, "sha": commit["sha"]})
    if st not in (200, 201, 204):
        die("ref update failed (HTTP %s): %s" % (st, body.get("_error", "")[:300]))

    log("DONE  branch=%s  batch=%s  files=%d  bytes=%d" % (branch, tag, len(kept), total))
    print()
    print("On Windows, double-click:  G:\\CloudDrop\\拉取云端文件.cmd")
    print()


if __name__ == "__main__":
    main()
