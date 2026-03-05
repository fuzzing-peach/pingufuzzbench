# WolfSSL `-W 1` 崩溃原因分析（OCSP Stapling）

## 结论
在当前复现配置下，`client` 传入 `-W 1`（请求 OCSP Stapling v1）会触发 `server` 在构造证书状态响应时访问空指针，导致 ASAN `SEGV`。

这不是网络连通性问题，而是服务端在 `certificate_status` 路径中的健壮性缺陷。

## 复现现象
使用本目录的 `run_repro.sh`（默认 `CLIENT_USE_W=1`）时，典型日志：

- client:
  - `wolfSSL_connect error -308, error state on socket`
- server:
  - `AddressSanitizer:DEADLYSIGNAL`
  - 栈顶：`CreateOcspResponse -> SendCertificateStatus -> wolfSSL_accept`

示例栈（简化）：

```text
#0 CreateOcspResponse .../src/internal.c:24543
#1 SendCertificateStatus .../src/internal.c:25334
#2 wolfSSL_accept       .../src/ssl.c:11087
#3 server_test          .../examples/server/server.c:3600
```

## 触发条件
满足以下条件时可稳定触发：

1. client 使用 `-W 1`，请求 OCSP stapled response。
2. server 进入 `SendCertificateStatus` 路径。
3. `CreateOcspResponse` 中 `ssl->buffers.certificate` 为 `NULL`（或不满足预期），但代码未先判空就解引用。

在本仓库当前参数组合中，`-s`（PSK）与 `-W` 同时启用时更容易触发该路径异常：

- 握手可走 PSK 套件（不依赖常规证书链交换）
- 但 `-W` 仍强制请求 `certificate_status`
- 进而触发服务端 OCSP 响应构造逻辑

## 关键代码路径

### 1) `SendCertificateStatus` 调用 `CreateOcspResponse`
`src/internal.c`（约 `25334` 行）：

```c
ret = CreateOcspResponse(ssl, &request, &response);
```

### 2) `CreateOcspResponse` 未判空 `der`
`src/internal.c`（约 `24539~24544` 行）：

```c
DerBuffer* der = ssl->buffers.certificate;

/* unable to fetch status. skip. */
if (der->buffer == NULL || der->length == 0)
    return 0;
```

问题点：`der` 可能为 `NULL`，但代码先访问 `der->buffer`，导致空指针解引用。

## 为什么是 server 崩溃而不是 client 崩溃
`-W 1` 的语义是“client 请求 stapling”。真正去生成 stapled OCSP response 的逻辑在 server 侧，因此崩溃发生在 server。client 的 `-308` 是服务端异常退出后的连带错误。

## 对照验证
在同样参数下去掉 client `-W`：

- ALPN、PSK 可正常协商（可看到 `TLS_DHE_PSK...` 与 `ALPN h2`）
- 无 ASAN 崩溃

说明基础通信正常，故障集中在 `certificate_status/OCSP stapling` 路径。

## 临时规避方案

1. 不使用 `-W`（若当前目标不是专测 stapling）。
2. 或避免与 `-s` 组合测试（改走证书握手路径再验证 stapling）。
3. 确保 server 的 OCSP stapling测试材料完整（证书链/OCSP资源）后再测。

## 建议修复（最小补丁思路）
在 `CreateOcspResponse` 中先判空 `der`：

```c
DerBuffer* der = ssl->buffers.certificate;
if (der == NULL || der->buffer == NULL || der->length == 0)
    return 0;
```

此修复至少可避免空指针崩溃；更完整的修复应结合握手模式（如 PSK）明确 `certificate_status` 不可用时的返回策略。

## 备注
本分析基于本仓库复现实验与本地源码路径：

- `target/ft/consumer/wolfssl/src/internal.c`
- `target/ft/consumer/wolfssl/src/ssl.c`
- `target/ft/consumer/wolfssl/examples/server/server.c`

以及本目录 Docker 化复现环境。
