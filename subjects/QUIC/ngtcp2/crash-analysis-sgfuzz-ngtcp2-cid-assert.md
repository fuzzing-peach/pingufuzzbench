# SGFuzz/ngtcp2 Crash 成因分析报告（CID 长度断言）

## 1. 结论

- 这次可复现的 crash（`crash-fa539da...`）本质是 **断言触发导致进程 abort**，不是越界写导致的内存破坏。
- 触发点在 `util::make_cid_key()`：
  - `examples/util.cc:328`
  - `assert(cid.size() <= NGTCP2_MAX_CIDLEN);`
- 调用路径在 `Server::read_pkt()` 中先把 `vc.dcidlen` 直接用于建 key，再做更严格包校验：
  - `examples/server.cc:2487` 先执行 `make_cid_key({vc.dcid, vc.dcidlen})`
  - `examples/server.cc:2493` 才执行 `ngtcp2_accept(...)`
- 因此，恶意/畸形 UDP 包可让 `vc.dcidlen > NGTCP2_MAX_CIDLEN`，从而命中断言并崩溃（远程 DoS）。

## 2. 复现摘要

- 重放对象（来自 `sgfuzz` 运行输出）：
  - `crash-1ec05cf...`（14B）: 不崩溃
  - `crash-bb2960a...`（39B）: 不崩溃
  - `crash-fa539da...`（105B）: 稳定崩溃
- `asan` 栈关键信息：
  - `ngtcp2::util::make_cid_key(...)` at `examples/util.cc:328`
  - `Server::read_pkt(...)` at `examples/server.cc:2487`
  - `Server::on_read(...)` at `examples/server.cc:2456`
  - `main` event loop at `examples/server.cc:3952`

## 3. 代码级根因

### 3.1 触发点

`examples/util.cc`:

```cpp
ngtcp2_cid make_cid_key(std::span<const uint8_t> cid) {
  assert(cid.size() <= NGTCP2_MAX_CIDLEN);
  ...
}
```

### 3.2 触发条件形成路径

`examples/server.cc`:

1. `ngtcp2_pkt_decode_version_cid(...)` 先解析出 `vc`（包含 `vc.dcidlen`）。
2. 紧接着执行：
   - `auto dcid_key = util::make_cid_key({vc.dcid, vc.dcidlen});`
3. 对包合法性的更强校验 `ngtcp2_accept(...)` 在后面才发生。

这会导致：只要 `decode_version_cid` 返回成功但给出异常大的 `dcidlen`，就会在 `assert` 处提前崩溃，校验逻辑来不及兜底。

## 4. 影响评估

- 影响类型：**可触发进程退出的拒绝服务（DoS）**。
- 触发面：UDP 输入可控场景（fuzzing、公开监听服务）。
- 严重度（工程角度）：中到高（单包触发退出，稳定复现）。

## 5. 修复建议

## 5.1 最小修复（推荐先做）

在 `Server::read_pkt()` 中，在 `make_cid_key` 之前增加长度检查：

```cpp
if (vc.dcidlen > NGTCP2_MAX_CIDLEN || vc.scidlen > NGTCP2_MAX_CIDLEN) {
  if (!config.quiet) {
    std::cerr << "Invalid CID length: dcid=" << vc.dcidlen
              << " scid=" << vc.scidlen << std::endl;
  }
  return;
}
```

## 5.2 防御性修复（建议同时做）

- 将 `util::make_cid_key` 从 `assert` 改成运行时检查（返回错误或空 key），避免 release/debug 构建行为差异。
- 保持“先校验、后使用”顺序：凡来自网络包的长度字段，在用于 `span`/拷贝/索引前都做上限检查。

## 6. 备注

- 该问题是 **断言式崩溃**，在启用断言的构建里表现为 `SIGABRT`，可能被误判为 ASAN 内存错误。
- 本次复现中，只有 `105B` 样本命中该路径，另外两个 crash 文件并未触发相同问题。  
