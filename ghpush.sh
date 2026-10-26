#!/usr/bin/env bash
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

msg=""
visibility="--private"
assume_yes=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m)
      [[ $# -ge 2 ]] || die "-m needs an argument"
      msg="$2"
      shift 2
      ;;
    --public)
      visibility="--public"
      shift
      ;;
    -y)
      assume_yes=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [-m \"commit message\"] [--public] [-y]"
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

command -v git >/dev/null || die "git is not installed"
command -v gh  >/dev/null || die "gh (GitHub CLI) is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not logged in; run: gh auth login"

# Require the current directory to be the Git repository root.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "current directory is not inside a Git repository"
[[ "$PWD" -ef "$repo_root" ]] \
  || die "run this script from the repository root: $repo_root"

name="$(basename "$PWD")"
[[ "$PWD" != "$HOME" && "$PWD" != "/" ]] \
  || die "refusing to publish $PWD"

# Avoid accidentally including changes that were already staged.
git diff --cached --quiet \
  || die "there are already staged changes; commit or unstage them first"

# Set up the GitHub remote if needed.
if ! git remote get-url origin >/dev/null 2>&1; then
  if url="$(gh repo view "$name" --json url -q .url 2>/dev/null)"; then
    git remote add origin "$url"
  else
    gh repo create "$name" "$visibility" --source=. --remote=origin
  fi
fi

# Stage the directory's non-ignored contents and record removals of tracked files.
git add -A -- .

if git diff --cached --quiet; then
  echo "==> Nothing to commit."
else
  echo "==> Changes to commit (D means a tracked file is absent here):"
  git diff --cached --name-status

  if [[ $assume_yes -eq 0 ]]; then
    [[ -t 0 ]] || die "confirmation needed; rerun with -y"
    read -r -p "Commit and push these changes? [y/N] " reply
    [[ "$reply" =~ ^[yY]([eE][sS])?$ ]] || {
      git reset -q
      echo "Aborted; no commit or push was made."
      exit 1
    }
  fi

  git commit -m "${msg:-Update $(date '+%Y-%m-%d %H:%M:%S')}"
fi

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "detached HEAD; check out a branch first"

git push -u origin "$branch"
echo "==> Done."
