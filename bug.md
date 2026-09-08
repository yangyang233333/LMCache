# MP 模式 L2 加载超时与 Prefetch Read Lock 泄漏

## 1. Bug 原因

LMCache multiprocess（MP）模式执行 lookup 时，如果 KV 数据只存在于 L2，daemon 会异步把数据加载到 L1。加载完成后，prefetch controller 会为最终保留的 KV 对象建立 read lock，防止对象在 worker 执行 RETRIEVE 前被淘汰。

正常流程如下：

```text
LOOKUP
  -> L2 异步加载
  -> 数据进入 L1
  -> 为最终 retained keys 建立 read lock
  -> 客户端取得命中结果
  -> RETRIEVE / FREE_LOOKUP_LOCKS
  -> 释放 read lock
```

原实现存在两个相关问题：

1. vLLM 没有覆盖整个 L2 prefetch 生命周期的总 deadline，只有单次 MQ 请求的 `mq_timeout`。
2. 客户端停止等待并返回 cache miss，并不会取消 daemon 中正在执行的 prefetch。

因此加入 L2 load timeout 后，可能出现以下时序：

```text
客户端发送 LOOKUP
  -> daemon 开始异步 L2 load
  -> 客户端等待超过 l2_load_timeout
  -> 客户端按 cache miss 继续 recompute
  -> 请求结束，发送 END_SESSION
  -> L2 load 此后才完成
  -> prefetch controller 在 L1 上建立 read lock
  -> 不再有 RETRIEVE 或 FREE_LOOKUP_LOCKS
  -> read lock 永久遗留
```

锁是在 prefetch controller 完成阶段建立的：

```python
l1_mgr.finish_write_and_reserve_read(
    loaded_keys,
    read_locks=request.num_kv_readers,
)
```

客户端超时时，锁可能已经建立，也可能尚未建立。因此，清理逻辑必须同时覆盖以下两种顺序：

```text
A. prefetch 完成并建锁 -> 客户端超时/请求结束
B. 客户端超时/请求结束 -> prefetch 后续完成并建锁
```

如果 read lock 没有释放，对应 L1 对象将无法正常淘汰。问题持续发生会逐渐降低 L1 可用容量。


## 2. 正常链路对应的代码位置

下面是正常流程中每一步对应的代码。

### 2.1 客户端发送 LOOKUP

#### vLLM

入口：

`lmcache/integration/vllm/vllm_multi_process_adapter.py:752`

```python
def maybe_submit_lookup_request(...):
```

实际向 LMCache daemon 发送 LOOKUP：

`lmcache/integration/vllm/vllm_multi_process_adapter.py:808`

```python
self.req_clients[url].lookup(key, self.tp_size)
```

#### SGLang

入口：

`lmcache/integration/sglang/multi_process_adapter.py:365`

```python
def lookup_kv(...):
```

发送 LOOKUP：

`lmcache/integration/sglang/multi_process_adapter.py:408`

```python
self.req_client.lookup(lookup_key, self.tp_size)
```

### 2.2 Daemon 接收 LOOKUP

服务端 handler：

`lmcache/v1/multiprocess/modules/lookup.py:201`

```python
def lookup(
    self,
    key: IPCCacheServerKey,
    tp_size: int,
) -> None:
```

该函数会计算 chunk hash、构造 object keys、创建 session，并提交 prefetch task：

`lmcache/v1/multiprocess/modules/lookup.py:348`

```python
handle = self._ctx.storage_manager.submit_prefetch_task(
    PrefetchRequestSpec(
        keys=obj_keys,
        num_kv_readers=num_kv_readers,
        ...
    ),
    external_request_id=key.request_id,
)
```

### 2.3 StorageManager 检查 L1 并提交 L2 加载

入口：

`lmcache/v1/distributed/storage_manager.py:410`

```python
def submit_prefetch_task(...):
```

StorageManager 首先检查 L1，并为已经存在于 L1 的对象 reserve read lock。对于需要从 L2 加载的对象，则提交给 prefetch controller：

`lmcache/v1/distributed/storage_manager.py:583`

```python
prefetch_request_id = (
    self._prefetch_controller.submit_prefetch_request(...)
)
```

不同策略分支的其他提交位置包括：

- `lmcache/v1/distributed/storage_manager.py:434`
- `lmcache/v1/distributed/storage_manager.py:486`

### 2.4 PrefetchController 异步执行 L2 加载

L2 prefetch 请求入口：

`lmcache/v1/distributed/storage_controllers/prefetch_controller.py:395`

```python
def submit_prefetch_request(...):
```

L2 adapter 完成加载后，统一进入完成处理：

`lmcache/v1/distributed/storage_controllers/prefetch_controller.py:1284`

```python
def _finish_request(
    self,
    request: InFlightPrefetchRequest,
) -> None:
```

这里汇总各 L2 adapter 的加载结果，并区分 `loaded_keys` 与 `failed_keys`。

### 2.5 数据进入 L1，并建立 Read Lock

真正将 write lock 转换为 read lock 的位置：

`lmcache/v1/distributed/storage_controllers/prefetch_controller.py:1349`

```python
l1_mgr.finish_write_and_reserve_read(
    loaded_keys,
    read_locks=request.num_kv_readers,
)
```

底层实现：

`lmcache/v1/distributed/l1_manager.py:598`

```python
def finish_write_and_reserve_read(
    self,
    keys: list[ObjectKey],
    read_locks: int = 1,
) -> dict[ObjectKey, L1OperationResult]:
```

之后 prefetch controller 根据加载结果和 attention window 计算最终 retained 集合，并发布结果：

`lmcache/v1/distributed/storage_controllers/prefetch_controller.py:1420`

```python
self._complete_request(request.request_id, retained)
```

结果保存位置：

`lmcache/v1/distributed/storage_controllers/prefetch_controller.py:1456`

```python
def _complete_request(
    self,
    request_id: PrefetchRequestId,
    result: Bitmap,
) -> None:
```

### 2.6 客户端取得命中结果

#### vLLM

客户端轮询入口：

`lmcache/integration/vllm/vllm_multi_process_adapter.py:863`

```python
def check_lookup_result(
    self,
    request_id: str,
) -> int | None:
```

它向 daemon 发送 `QUERY_PREFETCH_STATUS`。

服务端 handler：

`lmcache/v1/multiprocess/modules/lookup.py:399`

```python
def query_prefetch_status(
    self,
    request_id: str,
) -> int | None:
```

底层从 StorageManager 取得最终 bitmap：

`lmcache/v1/distributed/storage_manager.py:693`

```python
def query_prefetch_status(
    self,
    handle: PrefetchHandle,
) -> Bitmap | None:
```

#### SGLang

客户端等待入口：

`lmcache/integration/sglang/multi_process_adapter.py:309`

```python
def _wait_for_lookup(self, request_id: str) -> int:
```

服务端 handler：

`lmcache/v1/multiprocess/modules/lookup.py:503`

```python
def wait_prefetch_status(
    self,
    request_id: str,
    timeout: float,
) -> int | None:
```

底层等待位置：

`lmcache/v1/distributed/storage_manager.py:666`

```python
def wait_prefetch_status(...):
```

等待结束后仍通过 `query_prefetch_status()` 获取最终 bitmap 和命中 chunk 数。

### 2.7 RETRIEVE 消费 KV

服务端 RETRIEVE handler：

`lmcache/v1/multiprocess/modules/lmcache_driven_transfer.py:1284`

```python
def retrieve(...):
```

读取 prefetched L1 数据：

`lmcache/v1/multiprocess/modules/lmcache_driven_transfer.py:1450`

```python
with self._ctx.storage_manager.read_prefetched_results(
    in_window_keys
) as window_objs:
```

GPU copy 入队后，安排 read lock 释放回调：

`lmcache/v1/multiprocess/modules/lmcache_driven_transfer.py:1485`

```python
submit_callback_to_stream(
    cache_context.cupy_stream,
    "finish_read_prefetched",
    prefetched_keys,
)
```

必须等 GPU stream 消费完成后才释放 read lock，防止 L1 对象在异步拷贝过程中被淘汰。

### 2.8 FREE_LOOKUP_LOCKS 主动释放

如果命中的 KV 不需要执行 RETRIEVE，例如已被推理引擎自身的 prefix cache 覆盖，客户端会发送 `FREE_LOOKUP_LOCKS`。

服务端 handler：

`lmcache/v1/multiprocess/modules/lookup.py:536`

```python
def free_lookup_locks(...):
```

它解析实际锁定的 object keys，然后调用：

`lmcache/v1/multiprocess/modules/lookup.py:581`

```python
self._ctx.storage_manager.finish_read_prefetched(
    obj_keys,
    read_locks=key.require_num_kv_readers(),
)
```

StorageManager 释放入口：

`lmcache/v1/distributed/storage_manager.py:384`

```python
def finish_read_prefetched(
    self,
    keys: list[ObjectKey],
    read_locks: int = 1,
) -> None:
```

最终调用 L1Manager：

`lmcache/v1/distributed/l1_manager.py:340`

```python
def finish_read(
    self,
    keys: list[ObjectKey],
    read_locks: int = 1,
) -> dict[ObjectKey, L1Error]:
```

当临时对象的 read lock 数量降为零时，对象可以被删除和释放。

### 2.9 链路汇总

```text
LOOKUP
  lmcache/integration/*/multi_process_adapter.py
  -> lmcache/v1/multiprocess/modules/lookup.py

L1 检查与 L2 异步加载
  -> lmcache/v1/distributed/storage_manager.py
  -> lmcache/v1/distributed/storage_controllers/prefetch_controller.py

数据进入 L1、建立 read lock
  -> PrefetchController._finish_request()
  -> L1Manager.finish_write_and_reserve_read()

客户端取得命中结果
  -> LookupModule.query_prefetch_status()
  -> LookupModule.wait_prefetch_status()

RETRIEVE 消费
  -> LMCacheDrivenTransfer.retrieve()
  -> StorageManager.read_prefetched_results()

释放 read lock
  -> StorageManager.finish_read_prefetched()
  -> L1Manager.finish_read()
```

## 3. 最终解法

### 2.1 增加独立 L2 加载超时

#### vLLM

新增 extra config：

```text
lmcache.mp.l2_load_timeout
```

- `> 0`：限制整个 lookup/prefetch 的等待时间。
- `0.0`：禁用新的总 deadline，保持历史行为。

提交 lookup 时记录 monotonic 时间。`check_lookup_result()` 每次轮询时检查总耗时，超过预算后返回 `0`，使 vLLM 按整请求 cache miss 重新计算。

#### SGLang

构造参数新增：

```python
l2_load_timeout: float = 0.0
```

启用时，该值作为 `WAIT_PREFETCH_STATUS` 的 daemon 等待预算。超时后返回 `0`，使 SGLang 重新计算，而不是把缓存加载超时升级为用户请求失败。

超时请求仍保留一条零命中的 pending lookup，保证请求结束时会向 daemon 发送 `END_SESSION`。

### 2.2 在 Prefetch Job 中保存准确的清理信息

`_PrefetchJob` 保存：

- `keys`：与 prefetch bitmap 索引一致的完整 object key 序列。
- `num_kv_readers`：每个 key 实际 reserve 的 read lock 数量。
- `status_claimed`：是否已有状态查询正在消费该 job 的最终结果。

清理时不通过命中 chunk 数推测锁集合，而是使用 prefetch controller 返回的最终 retained bitmap：

```python
obj_keys = retained.gather(job.keys)
storage_manager.finish_read_prefetched(
    obj_keys,
    read_locks=job.num_kv_readers,
)
```

这样可以正确处理：

- 部分 L2 load 失败；
- sliding-window attention；
- 多 object group；
- sparse 或非连续 retained 集合；
- `num_kv_readers > 1`。

### 2.3 END_SESSION 接管未消费的 Prefetch Job

服务端收到 `END_SESSION` 时，先尝试从 `_prefetch_jobs` 中原子取出对应 job：

```text
job 仍在表中
  -> 客户端尚未成功消费最终结果
  -> END_SESSION 取得清理所有权
  -> job 加入 abandoned cleanup 队列
```

之后再删除 session。清理所有权由 prefetch job 持有，不依赖 session 是否仍然存在。

### 2.4 单后台 Worker 清理 Abandoned Jobs

`LookupModule` 使用一个后台 cleanup worker 管理所有 abandoned jobs，避免每个超时请求创建独立线程。

worker 周期性执行：

```text
查询 prefetch 最终结果
  -> 尚未完成：放回队列，稍后重试
  -> 已完成：取得 retained bitmap
  -> 释放 bitmap 对应的全部 read locks
```

因此两种竞态都能被覆盖：

```text
A. prefetch 先完成
prefetch 建锁 -> END_SESSION -> worker 立即取得 bitmap 并释放

B. 请求先结束
END_SESSION -> job 进入 abandoned 队列 -> prefetch 后续完成并建锁
-> worker 取得 bitmap -> 释放
```

### 2.5 保证 Status 与 Cleanup 只有一个消费者

`QUERY_PREFETCH_STATUS` 和 `END_SESSION` 可能并发处理同一个 job。

通过 `_prefetch_job_lock` 和 `status_claimed` 保证：

1. status 查询先原子 claim job；
2. 已被 status claim 的 job 不能被 `END_SESSION` 接管；
3. 查询返回未完成时恢复 claim；
4. 查询抛异常时也恢复 claim；
5. 查询取得最终结果后从 job 表移除；
6. `END_SESSION` 接管后从 job 表移除并交给 cleanup worker。

因此每个 prefetch 最终结果只有一个消费者，避免重复释放或结果被错误消费。

### 2.6 unhealthy 状态下仍发送清理请求

vLLM adapter 原先在 server 被标记为 unhealthy 后会直接跳过 `end_session()`。

但一次 MQ timeout 不代表之前的 LOOKUP 没有到达 daemon。它可能已经开始执行，并在之后建立 read lock。

修复后，只要本地记录表明该请求曾提交 lookup，即使当前 server 被标记为 unhealthy，也会尝试发送 `END_SESSION`，避免吞掉资源清理通知。

### 2.7 Shutdown 处理

LookupModule 关闭时：

1. 通知 cleanup worker 停止；
2. worker 处理队列中已经完成、可以立即释放的 job；
3. 对仍未完成的 job 不无限等待；
4. 随后 StorageManager 关闭 prefetch controller，并清理仍在飞请求持有的资源。

## 4. 修改文件

- `lmcache/integration/vllm/vllm_multi_process_adapter.py`
  - 新增 `l2_load_timeout`。
  - 超时后返回 cache miss。
  - unhealthy 状态下仍对已提交 lookup 尝试发送 `END_SESSION`。

- `lmcache/integration/sglang/multi_process_adapter.py`
  - 新增 `l2_load_timeout`。
  - 超时后返回 cache miss。
  - 保留 pending lookup，确保最终发送 `END_SESSION`。

- `lmcache/v1/multiprocess/modules/lookup.py`
  - 保存 prefetch keys、reader 数量和 status claim 状态。
  - `END_SESSION` 接管未消费 job。
  - 使用单 cleanup worker 等待完成并按 retained bitmap 清锁。
  - 实现 status 与 cleanup 的原子所有权控制和异常回滚。

- `tests/v1/multiprocess/test_lookup_wait_prefetch.py`
  - 覆盖完成前结束、完成后结束、并发 status/end、异常回滚和防重复释放。

- `tests/v1/multiprocess/test_free_locks.py`
  - 覆盖 unhealthy 但存在 lookup 时仍发送清理请求。

- `tests/v1/test_sglang_mp_adapter.py`
  - 覆盖 timeout fallback 和最终 `END_SESSION` 清理通知。

## 5. 验证结果

相关测试覆盖：

- prefetch 已完成后收到 `END_SESSION`；
- `END_SESSION` 后 prefetch 才完成；
- status 查询与 `END_SESSION` 并发；
- status 查询异常后的 claim 回滚；
- 正常消费后不发生 double-release；
- retained bitmap 精确释放；
- `num_kv_readers > 1`；
- SGLang timeout fallback；
- vLLM unhealthy 状态下仍发送 cleanup 通知。

执行结果：

```text
82 passed
```

另外：

- `py_compile` 通过；
- `git diff --check` 通过；
- 当前远程虚拟环境未安装 Ruff，因此没有运行 Ruff 检查。
