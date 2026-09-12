# [P2] 更新已有对象时，提前返回遗漏写预约通知

## 状态与范围

- 状态：成功更新不触发 listener 的行为已复现，待修复。
- 审查日期：2026-09-10。
- 审查版本：`7d9d54dd` 加现有构造函数调试 print。
- 直接影响是通知契约和可观测性；未证实因此造成现有淘汰或后台存储故障。

## 代码位置

- `lmcache/v1/distributed/l1_manager.py:492`：不需要分配时直接返回。
- `lmcache/v1/distributed/l1_manager.py:496`：`mode="update"` 分支提前返回。
- `lmcache/v1/distributed/l1_manager.py:527`：被跳过的 listener 回调与事件发布。

## 问题与根因

处理已有对象时，代码已加写锁并记录 `successful_keys`。但如果不需要分配新对象，或进入 update 模式的提前返回分支，就不会执行统一的 `on_l1_keys_reserved_write(successful_keys)` 回调，也不会发布 `L1_WRITE_RESERVED` 事件。

通知是否发生取决于是否执行后续分配，而不是是否成功建立写预约。

## 最小复现

使用真实 L1Manager；仅 listener 使用 `Mock(spec=L1ManagerListener)`：

1. 创建普通 key，调用 `finish_write()`。
2. 注册 mock listener，确保之前创建过程不计入调用次数。
3. 调用 `reserve_write([key], [False], layout, mode="update")`。
4. 检查返回结果和 `listener.on_l1_keys_reserved_write.call_count`。

实际输出：

```text
result = L1Error.SUCCESS
callback_count = 0
```

预期：成功预约应收到一次包含成功 key 的对应通知。事件发布缺失由同一提前返回路径确认，原复现未额外安装事件订阅器统计次数。

## 影响边界

- 写预约日志/事件流与实际锁状态不一致。
- 依赖该 listener 契约的扩展无法观察成功更新。
- 已检查的内置 store 和 eviction listener 对 reserved-write 回调为 no-op，因此不声称已造成它们的状态损坏。

## 修复方向

将成功预约的回调与事件发布整理到统一出口。没有新分配、update 模式含不存在 key、混合成功失败等路径，都应通知真正成功的 key，且仅通知一次。

## 回归验收

- [ ] `mode="update"` 成功更新已有 key 时通知一次。
- [ ] `mode="all"` 全部为已有可写 key 时通知一次。
- [ ] update 模式混合存在与不存在 key，仅通知成功子集。
- [ ] 包含新分配的路径不出现重复通知。
- [ ] listener 与事件总线的成功 key 集合一致。
