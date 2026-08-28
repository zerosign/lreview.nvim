#!/usr/bin/env fish
# Create a fresh test PR/MR on the sample repo so the full review flow
# (start -> comment -> submit) can be exercised repeatedly without polluting
# the seeded sample data.
#
# Usage:
#   ./scripts/make-test-pr.fish github   # GitHub sample repo
#   ./scripts/make-test-pr.fish gitlab   # GitLab sample repo
#
# Creates a uniquely-named branch, makes a small change, pushes it, opens a
# PR/MR, and checks out the branch so LocalReviewStart resolves it by branch.

set -l PROJECT_ROOT (realpath (dirname (status filename))/..)

set -l provider (test -n "$argv[1]"; and echo "$argv[1]"; or echo github)
set -l stamp (date +%s)
set -l branch "test/run-$stamp"

# repo_dir is set with -g so it survives the switch block scope (fish scopes
# `set -l` to the enclosing block).
set -g repo_dir ""
switch "$provider"
  case github
    set repo_dir "$PROJECT_ROOT/tmp/github-sample-review"
  case gitlab
    set repo_dir "$PROJECT_ROOT/tmp/gitlab-sample-review"
  case '*'
    echo "usage: $argv[0] {github|gitlab}" >&2
    exit 1
end

cd "$repo_dir"

# Fetch so origin refs are current, then determine the default branch.
git fetch origin 2>/dev/null; or true
set -l default_branch (git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | string replace 'refs/remotes/origin/' '')
if test -z "$default_branch"
  # Fall back to a known default.
  if git show-ref --verify --quiet refs/heads/main
    set default_branch main
  else
    set default_branch master
  end
end

# Ensure we start from a clean base on the default branch.
git checkout "$default_branch" 2>/dev/null
git reset --hard "origin/$default_branch" 2>/dev/null; or true
git pull --ff-only 2>/dev/null; or true

# Create the test branch and a small change.
git checkout -b "$branch"
echo "# test run $stamp" >> README.md
git add README.md
git commit -m "test: run $stamp"

# Push and open the PR/MR.
git push -u origin "$branch"

if test "$provider" = github
  gh pr create --base "$default_branch" --head "$branch" --title "Test run $stamp" --body "Automated test PR for run $stamp"
else
  glab mr create --source-branch "$branch" --target-branch "$default_branch" --title "Test run $stamp" --description "Automated test MR for run $stamp"
end

echo "created $provider test branch '$branch' (checked out, default=$default_branch)"
