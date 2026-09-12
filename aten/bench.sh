#!/usr/bin/env bash
set -euo pipefail

# 根据脚本所在位置计算仓库路径，确保可以从任意目录执行。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="${VENV_DIR:-${REPO_ROOT}/.venv}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
MODEL_NAME="${MODEL_NAME:-Qwen3-0.6B}"
MODEL_DIR="${MODEL_DIR:-/home/cxy/models/Qwen3-0.6B}"
RESULT_DIR="${RESULT_DIR:-${REPO_ROOT}/AAA/bench-results}"

# 默认使用重复前缀数据集，以便观察 LMCache 对共享前缀 KV Cache 的复用效果。
# 下面的参数都可以在命令行临时覆盖，例如：
# NUM_PROMPTS=100 PREFIX_LEN=4096 REQUEST_RATE=4 ./AAA/bench.sh
# 单请求示例如下：
# NUM_PROMPTS=1 NUM_PREFIXES=1 PREFIX_LEN=16 OUTPUT_LEN=1 REQUEST_RATE=4 SUFFIX_LEN=0 ./AAA/bench.sh

NUM_PROMPTS="${NUM_PROMPTS:-40}"
NUM_PREFIXES="${NUM_PREFIXES:-4}"
PREFIX_LEN="${PREFIX_LEN:-2048}"
SUFFIX_LEN="${SUFFIX_LEN:-128}"
OUTPUT_LEN="${OUTPUT_LEN:-64}"
REQUEST_RATE="${REQUEST_RATE:-2}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-4}"

if [[ ! -x "${VENV_DIR}/bin/vllm" ]]; then
  echo "未找到 vLLM：${VENV_DIR}/bin/vllm" >&2
  exit 1
fi

# Benchmark 客户端需要 tokenizer 来生成指定 token 数量的测试请求。
# MODEL_NAME 是 API 中注册的服务名，不是 Hugging Face 仓库名，因此这里
# 必须显式指定已经下载好的本地模型目录，避免访问错误的 Qwen3-0.6B 仓库。
if [[ ! -f "${MODEL_DIR}/tokenizer_config.json" ]]; then
  echo "未找到本地 tokenizer：${MODEL_DIR}" >&2
  exit 1
fi

# 先检查 API 服务，避免 benchmark 启动后才发现 vLLM 尚未就绪。
if ! curl --fail --silent --show-error --max-time 5 "${BASE_URL}/health" >/dev/null; then
  echo "vLLM 服务不可用：${BASE_URL}" >&2
  echo "请先执行 ./AAA/qyy.sh 启动 LMCache MP Server 和 vLLM。" >&2
  exit 1
fi

mkdir -p "${RESULT_DIR}"

cat <<INFO
开始 LMCache + vLLM Benchmark：
  API 地址:       ${BASE_URL}
  模型名称:       ${MODEL_NAME}
  Tokenizer 路径: ${MODEL_DIR}
  请求数量:       ${NUM_PROMPTS}
  共享前缀数量:   ${NUM_PREFIXES}
  前缀长度:       ${PREFIX_LEN} tokens
  后缀长度:       ${SUFFIX_LEN} tokens
  输出长度:       ${OUTPUT_LEN} tokens
  请求速率:       ${REQUEST_RATE} req/s
  最大并发:       ${MAX_CONCURRENCY}
  结果目录:       ${RESULT_DIR}
INFO

# prefix_repetition 会为多个请求生成相同前缀。第一次请求负责写入 KV Cache，
# 后续共享同一前缀的请求可从 LMCache 读取缓存，适合观察 TTFT 和吞吐变化。
exec "${VENV_DIR}/bin/vllm" bench serve \
  --backend vllm \
  --base-url "${BASE_URL}" \
  --model "${MODEL_NAME}" \
  --served-model-name "${MODEL_NAME}" \
  --tokenizer "${MODEL_DIR}" \
  --dataset-name prefix_repetition \
  --num-prompts "${NUM_PROMPTS}" \
  --prefix-repetition-num-prefixes "${NUM_PREFIXES}" \
  --prefix-repetition-prefix-len "${PREFIX_LEN}" \
  --prefix-repetition-suffix-len "${SUFFIX_LEN}" \
  --prefix-repetition-output-len "${OUTPUT_LEN}" \
  --request-rate "${REQUEST_RATE}" \
  --max-concurrency "${MAX_CONCURRENCY}" \
  --save-result \
  --result-dir "${RESULT_DIR}"
