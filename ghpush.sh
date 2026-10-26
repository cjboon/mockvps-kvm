#!/usr/bin/env bash
#
# ghpush.sh -- commit and push everything in the current directory to a GitHub
# repo named after the directory, using the GitHub CLI (gh).
#
#   * Repo name = the current directory's name.
#   * Not a git repo yet?        -> git init
#   * No GitHub remote yet?      -> reuse your repo of that name if it exists,
#                                   otherwise create it with gh (private by default)
#   * Then: git add -A, commit, push.
#
# Usage: ghpush.sh [-m "commit message"] [--public] [-y]
#   -m MSG      commit message (default: "Update <timestamp>")
#   --public    create the repo as public (default: private; only used on creation)
#   -y          don't ask for confirmation
#
# Requires: git, gh (already logged in: gh auth login)

set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

msg=""; visibility="--private"; assume_yes=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m)       [[ $# -ge 2 ]] || die "-m needs an argument"; msg="$2"; shift 2 ;;
    --public) visibility="--public"; shift ;;
    -y)       assume_yes=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)        die "unknown option: $1 (try --help)" ;;
  esac
done

command -v git >/dev/null || die "git is not installed"
command -v gh  >/dev/null || die "gh (GitHub CLI) is not installed: https://cli.github.com"
gh auth status >/dev/null 2>&1 || die "gh is not logged in; run: gh auth login"

name="$(basename "$PWD")"
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die "directory name '$name' is not a valid GitHub repo name (letters, digits, . _ - only)"
[[ "$PWD" != "$HOME" && "$PWD" != "/" ]] \
  || die "refusing to publish $PWD; cd into a project directory first"

# 1. Local repo
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "==> Not a git repository; running git init"
  git init -q -b main
fi

# 2. Remote
if ! git remote get-url origin >/dev/null 2>&1; then
  if url="$(gh repo view "$name" --json url -q .url 2>/dev/null)"; then
    echo "==> Using your existing GitHub repo: $url"
    git remote add origin "$url"
  else
    echo "==> Creating GitHub repo '$name' (${visibility#--})"
    gh repo create "$name" "$visibility" --source=. --remote=origin >/dev/null
  fi
fi

# 3. Show what will be committed, and confirm
git add -A
if git diff --cached --quiet; then
  echo "==> Nothing new to commit."
else
  echo "==> Files to be committed:"
  git status --short
  if [[ $assume_yes -eq 0 ]]; then
    [[ -t 0 ]] || { git reset -q; die "confirmation needed but stdin is not a terminal; re-run with -y"; }
    read -r -p "Commit and push these to $(git remote get-url origin)? [y/N] " reply
    [[ "$reply" =~ ^[yY]([eE][sS])?$ ]] || { git reset -q; die "aborted; nothing committed"; }
  fi
  git commit -q -m "${msg:-Update $(date '+%Y-%m-%d %H:%M:%S')}"
fi

# 4. Push
git rev-parse --verify HEAD >/dev/null 2>&1 || die "no commits to push"
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "detached HEAD; check out a branch first"
echo "==> Pushing '$branch' to origin"
git push -u origin "$branch"
echo "==> Done: $(git remote get-url origin)"
