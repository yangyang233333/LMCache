# [P2] 重复 key 导致 L1 预约结果与锁状态不一致

## 状态与范围

- 状态：已有对象的重复写预约、重复读预约均已复现，待修复。
- 审查日期：2026-09-10。
- 审查版本：`7d9d54dd` 加现有构造函数调试 print。
- 已确认 API 层行为；尚未证明正常推理请求一定会生成重复 key。

## 代码位置

- `lmcache/v1/distributed/l1_manager.py:473`：写预约按列表遍历，结果按 key 写入字典。
- `lmcache/v1/distributed/l1_manager.py:287`：读预约按出现次数增加锁计数。
- `lmcache/v1/distributed/l1_manager.py:341`：读取完成按输入列表释放。

## 问题与根因

输入是可能包含重复元素的 `list[ObjectKey]`，但输出是天然去重的字典。代码没有预先拒绝或归一化重复 key，导致同一对象多次发生状态变更，而调用方只能看到一次结果。

## 最小复现：写预约

1. 创建普通 key，调用 `finish_write()` 使其 ready。
2. 调用 `reserve_write([key, key], [False, False], layout, mode="update")`。

第一次遍历成功加写锁，第二次因为已有写锁而失败；失败结果覆盖前一次成功结果。

实际输出：

```text
result[key] = (L1Error.KEY_NOT_WRITABLE, None)
write_locked = True
```

预期：拒绝重复输入时不能产生任何预约副作用；若支持去重，则返回一次成功且仅持有一份相应预约。

影响：调用方认为预约失败，没有拿到 MemoryObj，可能不执行对应 finish/cleanup，使对象处于无人负责完成的写锁状态。

## 最小复现：读预约

1. 创建普通 key 并正常完成写入。
2. `result = reserve_read([key, key])`。
3. 调用 `finish_read(list(result))` 释放返回的成功 key。
4. 调用 `delete([key])`。

实际输出：

```text
unique_result_keys = 1
delete_after_release = KEY_IS_LOCKED
```

原因：读锁增加两次，返回字典只有一个 key，按返回结果归还时只释放一次。

## 新对象分配的证据边界

重复新 key 会被多次加入待分配列表，随后覆盖同一个字典条目。原实验观察到对象析构警告，但 CPU MemoryObj 的析构兜底回收了被覆盖空间，删除最终对象后测得泄漏字节数为 0。因此不将“永久内存泄漏”列为已确认影响；其他分配后端未验证。

## 修复方向

- 在任何状态修改之前拒绝重复 key，或明确采用保序去重语义。
- 若去重，同一 key 的 `is_temporary` 参数冲突也必须有明确处理规则。
- 读预约、写预约、完成和写转读接口应具有一致的重复输入语义。
- 不通过只保留第一次返回值来掩盖额外的锁计数变更。

## 回归验收

- [ ] 已有对象重复写预约不会返回失败却留下新写锁。
- [ ] 重复读输入不会产生输出无法表达的额外预约。
- [ ] 重复新 key 不触发冗余分配或依赖析构兜底。
- [ ] 非重复批量输入和多消费者 `read_locks` 参数行为保持不变。
