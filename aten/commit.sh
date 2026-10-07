#!/usr/bin/env bash

# 备份 qyy0905 分支上 aten/ 目录中的改动。
# 脚本会将 qyy0905 rebase 到 upstream/dev，把 aten/ 改动提交为 qyybackup，
# 压缩连续的 qyybackup 提交，并推送到配置的远端。

#===============================================================================
# 全局配置
#===============================================================================

set -euo pipefail

COMMIT_MESSAGE="qyybackup"
COMMIT_AUTHOR="HelloKitty <hfutqyy@163.com>"

#===============================================================================
# 路径解析与校验
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
ATEN_PATH="${SCRIPT_DIR#"${REPO_ROOT}/"}"

if [[ "${SCRIPT_DIR}" == "${REPO_ROOT}" || "${ATEN_PATH}" == "${SCRIPT_DIR}" ]]; then
  echo "ATEN directory is not inside the Git repository" >&2
  exit 1
fi

cd "${REPO_ROOT}"

#===============================================================================
# rebase 到 upstream/dev
#===============================================================================

# 记录现有 stash；只有本次确实创建了 stash 时才恢复它。
stash_before="$(git stash list --format='%H')"
git stash

git fetch upstream
git rebase upstream/dev

stash_after="$(git stash list --format='%H')"
if [[ "${stash_after}" != "${stash_before}" ]]; then
  git stash pop
fi

#===============================================================================
# 清理压测结果
#===============================================================================

# 删除压测文件夹
rm -rf "${SCRIPT_DIR}/bench-results"

#===============================================================================
# 分支与远端校验
#===============================================================================

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

#===============================================================================
# 提交 aten/ 改动
#===============================================================================

# 只暂存 aten/ 目录；仓库其他位置的改动保持原样。
git add -A -- "${ATEN_PATH}"

if ! git diff --cached --quiet -- "${ATEN_PATH}"; then
  git commit --only --author="${COMMIT_AUTHOR}" -m "${COMMIT_MESSAGE}" -- "${ATEN_PATH}"
else
  echo "No changes under ${ATEN_PATH} to commit."
fi

#===============================================================================
# 压缩连续 qyybackup 提交
#===============================================================================

# 统计分支顶端连续的 qyybackup 提交数量。
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

#===============================================================================
# 推送到远端
#===============================================================================

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
