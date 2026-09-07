#!/usr/bin/env bash
set -euo pipefail

# 根据脚本所在位置计算仓库路径，确保从任意目录执行都能正常工作。0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${VENV_DIR:-${REPO_ROOT}/.venv}"
MODEL_DIR="${MODEL_DIR:-/home/cxy/models/Qwen3-0.6B}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"

# LMCache MP Server 和 vLLM 服务参数。所有参数都可以在启动时覆盖，
# 例如：LMCACHE_L1_SIZE_GB=20 VLLM_PORT=8001 ./AAA/qyy.sh
LMCACHE_HOST="${LMCACHE_HOST:-127.0.0.1}"
LMCACHE_PORT="${LMCACHE_PORT:-5555}"
LMCACHE_L1_SIZE_GB="${LMCACHE_L1_SIZE_GB:-10}"
VLLM_PORT="${VLLM_PORT:-8000}"

# 提前检查所选虚拟环境中是否安装了 LMCache 和 vLLM。
for command_path in "${VENV_DIR}/bin/lmcache" "${VENV_DIR}/bin/vllm"; do
  if [[ ! -x "${command_path}" ]]; then
    echo "Required command not found: ${command_path}" >&2
    exit 1
  fi
done

# 检查本地模型目录，避免使用缺失或未下载完整的模型启动 vLLM。
if [[ ! -f "${MODEL_DIR}/config.json" ]]; then
  echo "Model not found at ${MODEL_DIR}" >&2
  exit 1
fi

# 优先使用指定的 CUDA Toolkit 和虚拟环境。默认使用 GPU 0，
# 如需使用第二张显卡，可在启动时设置 CUDA_VISIBLE_DEVICES=1。
export CUDA_HOME
export PATH="${CUDA_HOME}/bin:${VENV_DIR}/bin:${PATH}"
export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${LD_LIBRARY_PATH:-}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"

# 记录后台 LMCache 进程；按 Ctrl+C 或 vLLM 退出时自动清理，
# 避免残留的 LMCache Server 持续占用端口和内存。
lmcache_pid=""
cleanup() {
  if [[ -n "${lmcache_pid}" ]] && kill -0 "${lmcache_pid}" 2>/dev/null; then
    echo "Stopping LMCache server (PID ${lmcache_pid})..."
    kill "${lmcache_pid}" 2>/dev/null || true
    wait "${lmcache_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# 以独立进程启动 LMCache Server。L1 是主机内存中的 KV Cache 层，
# 最大容量为 LMCACHE_L1_SIZE_GB GiB，并使用 LRU 策略淘汰缓存。
echo "Starting LMCache MP server on ${LMCACHE_HOST}:${LMCACHE_PORT}..."
lmcache server \
  --host "${LMCACHE_HOST}" \
  --port "${LMCACHE_PORT}" \
  --l1-size-gb "${LMCACHE_L1_SIZE_GB}" \
  --eviction-policy LRU \
  --chunk-size "${LMCACHE_CHUNK_SIZE:-256}" &
lmcache_pid=$!

# 最多等待 30 秒，直到 LMCache 的 ZMQ TCP 端口可以连接。
# 如果 Server 在启动期间异常退出，则立即终止脚本并返回错误。
for _ in {1..30}; do
  if ! kill -0 "${lmcache_pid}" 2>/dev/null; then
    echo "LMCache server exited during startup" >&2
    wait "${lmcache_pid}"
  fi
  if timeout 1 bash -c "</dev/tcp/${LMCACHE_HOST}/${LMCACHE_PORT}" 2>/dev/null; then
    break
  fi
  sleep 1
done

if ! timeout 1 bash -c "</dev/tcp/${LMCACHE_HOST}/${LMCACHE_PORT}" 2>/dev/null; then
  echo "LMCache server did not listen on ${LMCACHE_HOST}:${LMCACHE_PORT}" >&2
  exit 1
fi

# 在前台启动 vLLM，并通过 MP Connector 连接 LMCache Server。
# recompute 表示缓存未命中或加载失败时，由 vLLM 正常重新计算 KV Cache。
echo "Starting vLLM on port ${VLLM_PORT}..."
vllm serve "${MODEL_DIR}" \
  --served-model-name Qwen3-0.6B \
  --host 0.0.0.0 \
  --port "${VLLM_PORT}" \
  --dtype bfloat16 \
  --max-model-len "${MAX_MODEL_LEN:-8192}" \
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.5}" \
  --kv-transfer-config \
  "{\"kv_connector\":\"LMCacheMPConnector\",\"kv_connector_module_path\":\"lmcache.integration.vllm.lmcache_mp_connector\",\"kv_role\":\"kv_both\",\"kv_load_failure_policy\":\"recompute\",\"kv_connector_extra_config\":{\"lmcache.mp.host\":\"tcp://${LMCACHE_HOST}\",\"lmcache.mp.port\":${LMCACHE_PORT}}}"
