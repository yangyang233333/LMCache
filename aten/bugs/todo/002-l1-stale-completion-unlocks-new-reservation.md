# [P1] 旧请求的完成通知会释放新请求的 L1 预约锁

## 状态与范围

- 状态：读侧和写侧均已在 API 层复现，待修复。
- 审查日期：2026-09-10。
- 审查版本：`7d9d54dd` 加现有构造函数调试 print。
- 未执行实际并发 DMA 或模型输出测试；已确认新预约的保护会被旧完成通知解除。

## 代码位置

- `lmcache/v1/distributed/l1_manager.py:341`：`finish_read()`，尤其检查当前读锁并 unlock 的路径。
- `lmcache/v1/distributed/l1_manager.py:538`：`finish_write()`，尤其检查当前写锁并 unlock 的路径。
- `lmcache/v1/distributed/l1_manager.py:599`：原子写转读入口也应纳入身份校验设计。
- `csrc/lmcache_native/ttl_lock.cpp:25`：过期后重新加锁会重新建立计数。

## 问题与根因

预约完成接口仅传 key（读侧另有计数），没有预约 token、generation 或所有者身份。旧预约过期后，同一个 key 可以建立新预约；旧操作迟到的完成通知只看到“现在有锁”，于是释放新预约的锁。

这不同于旧操作自身超过 TTL：被破坏的是新操作尚未过期的有效保护。

## 最小复现：读侧

使用真实 L1Manager 和原生 TTLLock，配置 `read_ttl_seconds=1`：

1. 创建 key 并正常完成写入。
2. 读者 A 调用 `reserve_read([key])`。
3. 等待 1.1 秒，让 A 的预约过期。
4. 读者 B 调用 `reserve_read([key])`，成功建立新预约。
5. 模拟 A 迟到的完成通知，调用 `finish_read([key])`。
6. B 尚未完成，调用 `delete([key])`。

实际输出：

```text
new_reader_reserved = SUCCESS
old_reader_finish = SUCCESS
delete_while_new_reader_active = SUCCESS
```

预期：A 的完成通知不能减少 B 的预约计数；B 完成之前普通删除必须被拒绝。

## 最小复现：写侧

配置 `write_ttl_seconds=1`：

1. 写者 A 对新 key 调用 `reserve_write()`。
2. 等待 1.1 秒。
3. 写者 B 对同一 key 调用 `reserve_write(..., mode="update")`，返回成功。
4. A 迟到地调用 `finish_write([key])`。
5. B 尚未完成写入，调用 `reserve_read([key])`。

实际输出：

```text
new_writer_reserved = SUCCESS
old_writer_finish = SUCCESS
read_while_new_writer_active = SUCCESS
```

预期：旧写者不能发布新写者尚未完成的数据。

## 影响与修复方向

可能导致使用中的空间被回收、覆盖，或者未完成数据提前对读者可见。需要为预约增加可验证的身份，完成通知只能归还对应预约；同时处理超时底层操作的取消、隔离及迟到通知。仅延长 TTL 不能根治。

此修复涉及调用方协议，不建议只局部修改锁计数；应先与维护者明确 TTL、预约所有权和异步完成语义。

## 回归验收

- [ ] 旧读者完成不释放新读者的锁。
- [ ] 旧写者完成不释放新写者的锁。
- [ ] 旧预约不能对同 key 的新一代对象执行完成操作。
- [ ] 多消费者预约与逐消费者释放仍保持配平。
- [ ] 重复、迟到完成通知的返回值与清理策略明确。
