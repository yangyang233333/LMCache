# [P1] 写锁过期后，未完成写入的 L1 对象被当作可读缓存

## 状态与范围

- 状态：已在 L1Manager API 层复现，待修复。
- 审查日期：2026-09-10。
- 审查版本：`7d9d54dd`，工作副本另有构造函数调试 print，不影响本问题。
- 未验证端到端模型输出异常；P1 是根据数据正确性风险给出的建议优先级。

## 代码位置

- `lmcache/v1/distributed/l1_manager.py:53`：`L1ObjectState.available_for_read()`。
- `lmcache/v1/distributed/l1_manager.py:247`：`reserve_read()`。
- `csrc/lmcache_native/ttl_lock.cpp:68`：`TTLLock::is_locked()`。

## 问题与根因

`available_for_read()` 只判断 `not self.write_lock.is_locked()`。原生锁在 TTL 到期后返回未锁定，但对象没有独立的“写入成功/数据有效”状态。因此，写入成功后主动释放写锁与写入未完成但锁超时，在可读性判断中无法区分。

## 最小复现

在远端仓库的 `.venv/bin/python` 中使用真实 L1Manager、原生 TTLLock 和 8 MiB CPU 共享内存池，配置 `write_ttl_seconds=1`、`read_ttl_seconds=30`。对象布局为 1024 个 float32 元素。

1. 对不存在的 key 调用 `reserve_write([key], [False], layout)`。
2. 不写数据，也不调用 `finish_write()`。
3. 等待 1.1 秒。
4. 调用 `reserve_read([key])`。

实际输出：

```text
unfinished_write_after_ttl: read_result = L1Error.SUCCESS
```

预期：未成功完成写入的对象不能作为有效缓存返回；应拒绝读取，或经过明确的失效/清理流程。

## 影响与触发条件

写入失败、调用方退出、清理遗漏或写入超时时，缓存对象可能暴露未初始化、部分写入或陈旧数据。默认写 TTL 为 600 秒；1 秒只是为了缩短复现实验，并非只有该配置才存在问题。

## 修复方向

- 把数据有效性与预约 TTL 分开建模，仅成功完成写入才能进入可读状态。
- 超时写入进入失效/待清理状态，不能自动转为 ready。
- 若底层异步写入仍可能访问空间，必须先取消、等待或隔离该操作，再安全回收，不能简单超时即 free。
- 与 `002-l1-stale-completion-unlocks-new-reservation.md` 一起讨论状态机，但分别验证其独立失败路径。

## 回归验收

- [ ] 写预约过期且未完成时，读预约失败。
- [ ] 正常写入完成后可读。
- [ ] 超时对象的清理不释放仍被底层操作使用的空间。
- [ ] 用可控时钟或等价机制覆盖过期分支，避免依赖脆弱的 sleep 测试。

## 既有验证

原审查运行 `tests/v1/distributed/test_l1_manager.py`，结果为 77 passed、84 warnings；现有测试通过不代表覆盖了此过期路径。
