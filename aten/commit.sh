#!/usr/bin/env bash
set -euo pipefail

COMMIT_MESSAGE="qyybackup"
COMMIT_AUTHOR="HelloKitty <hfutqyy@163.com>"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
ATEN_PATH="${SCRIPT_DIR#"${REPO_ROOT}/"}"

if [[ "${SCRIPT_DIR}" == "${REPO_ROOT}" || "${ATEN_PATH}" == "${SCRIPT_DIR}" ]]; then
  echo "ATEN directory is not inside the Git repository" >&2
  exit 1
fi

cd "${REPO_ROOT}"

# rebase一下
bash -e "${SCRIPT_DIR}/rebase.sh"
# 删除压测文件夹
rm -rf "${SCRIPT_DIR}/bench-results"

branch="$(git symbolic-ref --quiet --short HEAD)" || {
  echo "Cannot commit from a detached HEAD" >&2
  exit 1
}

if [[ "${branch}" != "qyy0905" ]]; then
  echo "Current branch is ${branch}; expected qyy0905. Aborting." >&2
  exit 1
fi

remote="${REMOTE:-origin}"
if ! git remote get-url "${remote}" >/dev/null 2>&1; then
  echo "Git remote does not exist: ${remote}" >&2
  exit 1
fi

# Stage only ATEN. Changes elsewhere in the repository remain untouched.
git add -A -- "${ATEN_PATH}"

if ! git diff --cached --quiet -- "${ATEN_PATH}"; then
  git commit --only --author="${COMMIT_AUTHOR}" -m "${COMMIT_MESSAGE}" -- "${ATEN_PATH}"
else
  echo "No changes under ${ATEN_PATH} to commit."
fi

# Collapse the consecutive qyybackup commits at the tip into one commit.
backup_count=0
while commit_metadata="$(git log -1 --format='%s%x09%an%x09%ae' "HEAD~${backup_count}" 2>/dev/null)"; do
  IFS=$'\t' read -r commit_subject commit_author_name commit_author_email <<< "${commit_metadata}"
  if [[ "${commit_subject}" != "${COMMIT_MESSAGE}" ||
        "${commit_author_name}" != "HelloKitty" ||
        "${commit_author_email}" != "hfutqyy@163.com" ]]; then
    break
  fi
  backup_count=$((backup_count + 1))
done

if (( backup_count > 1 )); then
  base_commit="$(git rev-parse "HEAD~${backup_count}")"
  git reset --soft "${base_commit}"

  if git diff --cached --quiet; then
    echo "Consecutive ${COMMIT_MESSAGE} commits cancel each other out; nothing to commit."
  else
    git commit --author="${COMMIT_AUTHOR}" -m "${COMMIT_MESSAGE}"
  fi
fi

remote_ref="refs/remotes/${remote}/${branch}"
if git show-ref --verify --quiet "${remote_ref}" && ! git merge-base --is-ancestor "${remote_ref}" HEAD; then
  if (( backup_count > 1 )); then
    git push --force-with-lease "${remote}" "HEAD:${branch}"
  else
    echo "Local branch is not a fast-forward of ${remote}/${branch}; refusing to push." >&2
    exit 1
  fi
else
  git push "${remote}" "HEAD:${branch}"
fi
