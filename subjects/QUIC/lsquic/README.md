# lsquic Fuzzing — 实现规划

## 1. 目标概述

为 [lsquic](https://github.com/litespeedtech/lsquic) 实现 PinguFuzzBench 标准化的 `config.sh`，支持以下三种 fuzzer 的 build + run：

- **AFLNet** — 网络协议灰盒 fuzzer，通过 UDP 与被测服务器交互
- **SGFuzz** — 基于状态机推断的 libfuzzer 模式 fuzzer，使用 honggfuzz netdriver
- **Fuzztruction (FT)** — 双程序 mutation 框架，generator 产生变异数据，consumer 接收

被测目标程序为 lsquic 的 `http_server`（位于 `bin/http_server`），监听 UDP 端口提供 QUIC 服务。

---

## 2. lsquic 关键特征（与 ngtcp2 的差异）

| 维度 | ngtcp2 | lsquic |
|------|--------|--------|
| TLS 后端 | WolfSSL | **BoringSSL**（需要 Go 编译） |
| 构建系统 | autotools (autoreconf + configure + make) | **CMake** |
| 被测二进制 | `examples/wsslserver` | **`bin/http_server`** |
| 启动参数 | `127.0.0.1 4433 key cert --initial-pkt-num=0` | **`-s 127.0.0.1:4433 -c domain,cert,key`**（v4.x 默认 QUIC v1，无需 `-Q`） |
| 依赖库 | wolfssl, nghttp3 | **BoringSSL**（+ Go 工具链）, libevent |
| QUIC 版本 | draft / v1 | **Q046, Q050, v1, v2**（v4.x 支持 RFC 9000 QUIC v1 及 v2） |
| 就绪信号 (FT) | N/A | **`Bind(0)`** — 日志中出现时表示服务器就绪 |
| 子模块 | 无 | **有**（`git submodule update --init`） |

---

## 3. 源码获取与 Patch 策略

### 3.1 checkout 函数

**需要获取的仓库：**

1. **lsquic** — `https://github.com/litespeedtech/lsquic.git`
   - 基线版本：**`v4.4.2`**（commit `342a9b3`，2026-01-04 发布，含多项 bug 修复和 BBR 优化）
   - ft-net-quicfuzzer 中的旧版本 `c4f359f` 过于陈旧，v4.4.2 是近期稳定版本
   - 获取后执行 `git submodule update --init`
2. **BoringSSL** — `https://boringssl.googlesource.com/boringssl`
   - 使用与 lsquic v4.4.2 兼容的版本（编译时由 lsquic 子模块或手动指定）
   - 需要 Go 工具链来编译（Go >= 1.22）

使用 `.git-cache/` 缓存克隆结果，`repo/` 存放工作副本（与 ngtcp2 保持一致）。

### 3.2 Patch — 随机数固定与时间固定

**目标：** 使 fuzzing 过程中的随机数和时间具有确定性，从而提高 fuzzer 的可复现性和效率。

**待办：实现前需先在 lsquic v4.4.2 和 BoringSSL 源码中实际排查以下两类接口的所有调用点，确认需要 patch 的确切位置。** 不应假设与 ft-net-quicfuzzer 旧版一致，v4.x 的代码路径可能已发生变化。

#### (a) 随机数固定 — 需排查的接口

需要在 lsquic 和 BoringSSL 源码中搜索所有随机数生成的入口，至少包括：

**BoringSSL 侧：**
- `RAND_bytes()` / `RAND_pseudo_bytes()` — 主要的密码学随机数接口
- `RAND_seed()` / `RAND_add()` — 随机数池注入
- 其他可能被 lsquic 直接调用的 BoringSSL 随机 API

**lsquic 侧：**
- lsquic 自身是否有独立的随机数生成逻辑（如 connection ID 生成、重试令牌等）
- `lsquic_crand_init()` / 相关 CRAND 接口
- `http_server` 示例程序中的随机数使用

**排查方法：**
```bash
# 在 lsquic 源码中搜索随机数相关调用
rg -n 'RAND_bytes|RAND_pseudo|rand\(|random\(|arc4random|getrandom|getentropy|/dev/urandom|crand' src/ bin/
# 在 BoringSSL 中定位 RAND_bytes 实现
rg -n 'RAND_bytes' crypto/
```

**参考思路：** `subjects/QUIC/ngtcp2/wolfssl-random.patch` 对 `wc_RNG_GenerateBlock()` 的处理方式——在最底层随机数生成函数中，检查 `FAKE_RANDOM` 环境变量，存在时用 `rand_r()` + 固定种子替代。

#### (b) 时间固定 — 需排查的接口

需要排查 lsquic 和 BoringSSL 中所有获取当前时间的路径：

**lsquic 侧：**
- `lsquic_time_now()` — lsquic 核心时间函数（可能基于 `clock_gettime`）
- `gettimeofday()` / `clock_gettime()` / `time()` 的直接调用
- `http_server` 中的事件循环时间获取

**BoringSSL 侧：**
- 证书验证中的时间检查（`X509_verify_cert` → `time()` / `X509_cmp_time`）
- TLS session ticket / OCSP 响应的时间检查
- BoringSSL 内部的 `OPENSSL_posix_to_tm` 等时间工具

**排查方法：**
```bash
# 在 lsquic 源码中搜索时间相关调用
rg -n 'time_now|clock_gettime|gettimeofday|time\(|CLOCK_MONOTONIC|CLOCK_REALTIME' src/ bin/
# 在 BoringSSL 中搜索时间相关
rg -n 'time\(|OPENSSL_posix_to_tm|X509_cmp_time' crypto/ include/
```

**参考思路：** `subjects/QUIC/ngtcp2/quicfuzz-ngtcp2.patch` 对 `timestamp()` / `system_clock_now()` 的处理——在时间获取函数中，首次调用时读取 `FAKE_TIME` 环境变量解析为基准时间，后续返回 `fake_base + (real_now - real_base)`。

#### (c) Patch 策略原则

- **尽量在最底层 patch**：在少数几个底层函数中集中处理，而非逐个 patch 上层调用点
- **环境变量控制**：所有 patch 均通过 `FAKE_RANDOM` / `FAKE_TIME` 环境变量开关，不影响正常使用
- **保持时间单调性**：fake time 必须单调递增，否则会导致 QUIC 协议逻辑异常
- **版本适配**：patch 必须针对 lsquic v4.4.2 和对应 BoringSSL 版本的实际代码编写，不可盲目复用旧版 patch

---

## 4. 函数实现计划

### 4.1 `install_dependencies`

```bash
sudo apt-get install -y libevent-dev cmake golang-go
```

如果系统 Go 版本不够，需下载 Go 二进制包（参考 ft-net-quicfuzzer 中的 `go1.22.3`）。

### 4.2 `build_aflnet`

**流程：**

1. 创建 `target/aflnet/` 目录，拷贝 `repo/boringssl` 和 `repo/lsquic`
2. **编译 BoringSSL：**
   - `CC=gcc CXX=g++`（BoringSSL 不直接用 AFL 插桩，因为我们 fuzz 的是 lsquic）
   - `cmake -DCMAKE_BUILD_TYPE=Release . && make -j`
3. **编译 lsquic（AFL 插桩）：**
   - `CC=${HOME}/aflnet/afl-clang-fast CXX=${HOME}/aflnet/afl-clang-fast++`
   - `AFL_USE_ASAN=1`
   - `CFLAGS="-g -O2 -fsanitize=address"`
   - `cmake -DBORINGSSL_DIR=<path> -DCMAKE_BUILD_TYPE=Release .`
   - `make -j`
4. 验证 `bin/http_server` 已生成

**参考：** ft-net-quicfuzzer 的 `build_consumer` / `build_consumer_afl_net` 函数。

### 4.3 `run_aflnet`

**流程：**

1. 设置环境变量：
   - `AFL_SKIP_CPUFREQ=1`, `AFL_NO_AFFINITY=1`, `AFL_NO_UI=1`
   - `FAKE_RANDOM=1`, `FAKE_TIME="2026-03-11 12:00:00"`
   - `ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:..."`
2. 运行 AFLNet：
   ```
   afl-fuzz -d -i $indir -o $outdir -N "udp://127.0.0.1/4433 " \
       -P NOP -D 10000 -q 3 -s 3 -K -R -W 100 -m none \
       -- bin/http_server -s 127.0.0.1:4433 \
       -c www.example.com,<cert>,<key>
   ```
3. 覆盖率收集（使用 gcov 目标 + `compute_coverage` + `gcovr`）

**关键参数说明：**
- `-N "udp://127.0.0.1/4433 "` — UDP 协议的网络地址
- `-P NOP` — 协议类型为 NOP（QUIC 没有 AFLNet 原生的协议解析器）
- `-s 127.0.0.1:4433` — lsquic 监听地址格式（v4.x 默认 QUIC v1，无需 `-Q` 指定版本）
- `-c www.example.com,cert,key` — lsquic 证书配置格式（逗号分隔：域名,证书,密钥）

### 4.4 `build_sgfuzz`

**流程：**

1. 创建 `target/sgfuzz/` 目录
2. **编译 BoringSSL：**
   - 使用 `gcc/g++`，普通编译（不插桩）
3. **SGFuzz 插桩 lsquic：**
   - `CC=wllvm CXX=wllvm++`
   - `CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING"`
   - `python3 ${HOME}/sgfuzz/sanitizer/State_machine_instrument.py .`
   - CMake 编译 lsquic
4. **提取 bitcode 并链接：**
   - `extract-bc bin/http_server`
   - 使用 `opt` + `sgfuzz-source-pass.so` 进行 SGFuzz pass
   - `llvm-dis` → 去除 `optnone` → clang 链接
   - 生成 `hf_udp_addr.c` — HonggFuzz netdriver 的 UDP 地址绑定（端口 4433）
   - 最终链接 `-lsFuzzer -lhfnetdriver -lhfcommon -fsanitize=address -fsanitize=fuzzer`

**参考：** ngtcp2 的 `build_sgfuzz` 流程 + ft-net-quicfuzzer 的 `build_consumer_sgfuzz` 编译参数。

### 4.5 `run_sgfuzz`

**流程：**

1. 设置环境变量：
   - `ASAN_OPTIONS`, `AFL_NO_AFFINITY=1`, `FAKE_RANDOM=1`, `FAKE_TIME`
   - `HFND_TCP_PORT=4433`（honggfuzz netdriver 端口）
   - `LD_LIBRARY_PATH` 指向 BoringSSL 库
2. 运行 libfuzzer 模式：
   ```
   ./http_server <SGFuzz_ARGS> -- -s 127.0.0.1:4433 -c ...
   ```
   SGFuzz_ARGS 包括：`-max_len=100000 -close_fd_mask=3 -shrink=1 -reload=30 -print_final_stats=1 -detect_leaks=0 -max_total_time=$timeout -artifact_prefix=...`
3. 排序语料 + 覆盖率收集

### 4.6 `build_ft_generator`

**流程（ngtcp2 客户端作为 generator）：**

FT 模式下，generator 是 **ngtcp2 的 QUIC 客户端**（与 ft-net-quicfuzzer 一致），consumer/sink 是 lsquic 的 `http_server`。

1. 创建 `target/ft/generator/` 目录
2. 编译 wolfssl（供 ngtcp2 使用）
3. 编译 nghttp3
4. **编译 ngtcp2（FT generator 插桩）：**
   - `CC=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast`
   - `FT_CALL_INJECTION=1`, `FT_HOOK_INS=branch,load,store,select,switch`
   - CMake 编译，产出 `build/examples/wsslclient`

**注意：** generator 侧需要同时获取和编译 ngtcp2 + wolfssl + nghttp3。

### 4.7 `build_ft_consumer`

**流程（lsquic 作为 consumer/sink）：**

1. 创建 `target/ft/consumer/` 目录
2. **编译 BoringSSL：**（普通编译，不插桩）
3. **编译 lsquic（AFL++ consumer 插桩）：**
   - `CC=${AFL_PATH}/afl-clang-fast CXX=${AFL_PATH}/afl-clang-fast++`
   - `AFL_PATH=${HOME}/fuzztruction-net/consumer/aflpp-consumer`
   - `CFLAGS="-O3 -g -fsanitize=address"`
   - `cmake -DBORINGSSL_DIR=<path> .`
   - `make -j`

### 4.8 `run_ft`

**流程：**

1. 合成 `ft.yaml` 配置文件：
   - 拼接 `ft-common.yaml` + `ft-source.yaml`（ngtcp2 客户端） + `ft-sink.yaml`（lsquic 服务器）
2. 运行 FT：
   ```
   sudo fuzztruction --log-level info ft.yaml fuzz -t ${timeout}s
   ```
3. 收集覆盖率：
   ```
   sudo fuzztruction --log-level info ft.yaml gcov -t 3s --replay-step ... --gcov-step ...
   ```

### 4.9 `build_gcov`

**流程：**

1. 普通编译 BoringSSL
2. 编译 lsquic，使用 `gcc/g++` + `CFLAGS="-fprofile-arcs -ftest-coverage"`
3. 产出的 `bin/http_server` 可用于覆盖率收集

### 4.10 `replay`

**流程：**

1. 启动 gcov 版 `http_server`（带 `LD_PRELOAD=libgcov_preload.so`）
2. 使用 `aflnet-replay` 回放测试用例到 UDP 端口 4433
3. 等待完成后 kill 服务器

---

## 5. 需要创建的 YAML 配置文件

### 5.1 `ft-source.yaml`（FT generator — ngtcp2 客户端）

```yaml
source:
  bin-path: "/home/user/target/ft/generator/ngtcp2/build/examples/wsslclient"
  env:
    - FAKE_RANDOM: "1"
    - FAKE_TIME: "2026-03-11 12:00:00"
  arguments: ["--exit-on-all-streams-close", "127.0.0.1", "4433"]
  working-dir: "/home/user/target/ft/generator/ngtcp2"
  input-type: Udp
  output-type: Udp
  is-server: false
  log-stdout: true
  log-stderr: true
```

### 5.2 `ft-sink.yaml`（FT consumer — lsquic 服务器）

```yaml
sink:
  bin-path: "/home/user/target/ft/consumer/lsquic/bin/http_server"
  env:
    - FAKE_RANDOM: "1"
    - FAKE_TIME: "2026-03-11 12:00:00"
  arguments:
    - "-s"
    - "127.0.0.1:4433"
    - "-c"
    - "www.example.com,/home/user/profuzzbench/cert/fullchain.crt,/home/user/profuzzbench/cert/server.key"
  working-dir: "/home/user/target/ft/consumer/lsquic"
  input-type: Udp
  output-type: Udp
  is-server: true
  server-port: "4433"
  server-ready-on: "Bind(0)"
  send-sigterm: true
  log-stdout: true
  log-stderr: true
  allow-unstable-sink: true
  persistent-server: true

gcov:
  bin-path: "/home/user/target/gcov/lsquic/bin/http_server"
  cwd: "/home/user/target/gcov/lsquic/"
  env:
    - LD_PRELOAD: "libgcov_preload.so"
    - FAKE_RANDOM: "1"
  src-dir: "/home/user/target/gcov/lsquic"
  reporter: "gcovr"
```

---

## 6. 需要创建的种子文件

在 `subjects/QUIC/lsquic/` 下创建：
- `seed/` — 原始 QUIC ClientHello 数据包（用于 SGFuzz / FT）
- `seed-replay/` — AFLNet 格式的 length-prefixed 种子（用于 AFLNet）

种子获取方式：使用 `init-seed-capture` skill，或手动：
1. 启动 lsquic http_server
2. 用 ngtcp2 客户端发起 QUIC 连接
3. tcpdump 抓取 client→server 的 UDP payload

---

## 7. 需要安装的额外依赖

```bash
# lsquic 编译依赖
sudo apt-get install -y libevent-dev cmake

# BoringSSL 编译依赖
# Go 工具链（如系统无 Go 或版本不够）
wget https://go.dev/dl/go1.22.3.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.22.3.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
```

---

## 8. 实现顺序与里程碑

### Phase 1: 基础设施
- [ ] 编写 `checkout` 函数（克隆 lsquic + BoringSSL，应用 patch）
- [ ] 编写 `install_dependencies` 函数
- [ ] 创建 `lsquic-random.patch`（BoringSSL 随机数固定）
- [ ] 创建 `lsquic-time.patch`（lsquic 时间固定）
- [ ] 编写 `build_gcov` 函数
- [ ] 编写 `replay` 函数
- [ ] 准备种子文件（`seed/` 和 `seed-replay/`）

### Phase 2: AFLNet
- [ ] 编写 `build_aflnet` 函数
- [ ] 编写 `run_aflnet` 函数
- [ ] 测试：短时间 fuzzing campaign 验证 AFLNet 可正常运行

### Phase 3: SGFuzz
- [ ] 编写 `build_sgfuzz` 函数（wllvm + extract-bc + sgfuzz-pass + 链接）
- [ ] 编写 `run_sgfuzz` 函数
- [ ] 测试：短时间 fuzzing campaign 验证 SGFuzz 可正常运行

### Phase 4: Fuzztruction (FT)
- [ ] 编写 `build_ft_generator` 函数（ngtcp2 客户端 + FT 插桩）
- [ ] 编写 `build_ft_consumer` 函数（lsquic 服务器 + AFL++ 插桩）
- [ ] 创建 `ft-source.yaml` 和 `ft-sink.yaml`
- [ ] 编写 `run_ft` 函数
- [ ] 测试：短时间 fuzzing campaign 验证 FT 可正常运行

---

## 9. 最终效果

完成后，`subjects/QUIC/lsquic/` 目录结构：

```
subjects/QUIC/lsquic/
├── README.md              # 本文档
├── config.sh              # 标准化构建脚本（checkout/build_*/run_*/replay/build_gcov）
├── lsquic-random.patch    # BoringSSL 随机数确定性 patch
├── lsquic-time.patch      # lsquic 时间确定性 patch
├── ft-source.yaml         # FT generator 配置（ngtcp2 客户端）
├── ft-sink.yaml           # FT consumer 配置（lsquic 服务器）
├── seed/                  # 原始 QUIC 种子
└── seed-replay/           # AFLNet 格式种子
```

可通过标准命令运行：

```bash
# 构建
./scripts/build.sh -t QUIC/lsquic -f aflnet -v v4.4.2
./scripts/build.sh -t QUIC/lsquic -f sgfuzz -v v4.4.2
./scripts/build.sh -t QUIC/lsquic -f ft -v v4.4.2

# Fuzzing
./scripts/run.sh -t QUIC/lsquic -f aflnet -v v4.4.2 --times 1 --timeout 3600 -o output
./scripts/run.sh -t QUIC/lsquic -f sgfuzz -v v4.4.2 --times 1 --timeout 3600 -o output
./scripts/run.sh -t QUIC/lsquic -f ft -v v4.4.2 --times 1 --timeout 3600 -o output
```

---

## 10. 注意事项与风险

1. **BoringSSL 需要 Go** — Docker 环境中需确保 Go 工具链可用；`install_dependencies` 或 Dockerfile 中需处理
2. **lsquic 的 CMake 构建** — 与其他 autotools 目标不同，需注意 `CMAKE_LIBRARY_PATH` / `CMAKE_INCLUDE_PATH` 的传递方式
3. **SGFuzz 链接复杂度** — lsquic 是 CMake 项目，`extract-bc` 提取 bitcode 后需手动处理库依赖路径
4. **FT generator 需要 ngtcp2** — generator 侧需额外编译 ngtcp2 + wolfssl + nghttp3，checkout 函数需同时处理
5. **Patch 的可移植性** — BoringSSL 和 lsquic 版本锁定后 patch 才稳定，版本升级需重新适配；v4.3.2+ 新增了 `LSQUIC_LIBSSL` CMake 选项可简化 TLS 库选择
6. **v4.x API 变化** — 相比 ft-net-quicfuzzer 使用的旧版 `c4f359f`，v4.x 有较多 API 和参数变更，`http_server` 的命令行参数需重新确认
6. **UDP vs TCP** — lsquic 是 QUIC 协议（UDP），AFLNet 需要 `udp://` netinfo，不同于 TLS 目标的 `tcp://`
7. **`-c` 参数格式** — lsquic 的证书参数格式为 `domain,cert_path,key_path`，用逗号分隔，与其他目标不同
