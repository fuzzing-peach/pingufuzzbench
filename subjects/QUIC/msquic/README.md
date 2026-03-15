# msquic Fuzzing — 实现规划

## 1. 目标概述

为 [msquic](https://github.com/microsoft/msquic)（微软跨平台 QUIC 实现）实现 PinguFuzzBench 标准化的 `config.sh`，支持以下三种 fuzzer 的 build + run：

- **AFLNet** — 网络协议灰盒 fuzzer，通过 UDP 与被测服务器交互
- **SGFuzz** — 基于状态机推断的 libfuzzer 模式 fuzzer，使用 honggfuzz netdriver
- **Fuzztruction (FT)** — 双程序 mutation 框架，generator 产生变异数据，consumer 接收

被测目标程序为 msquic 的 `quicsample`（位于 `bin/Release/quicsample`），是 msquic 提供的示例 QUIC 服务器/客户端工具。

---

## 2. msquic 关键特征（与 ngtcp2 的差异）

| 维度 | ngtcp2 | msquic |
|------|--------|--------|
| 语言 | C++ | **C**（跨平台，支持 Windows/Linux/macOS） |
| TLS 后端 | WolfSSL | **OpenSSL 3**（通过子模块 `opensslquic` 内置） |
| 构建系统 | autotools | **CMake**（+ 可选 PowerShell 脚本 `scripts/build.ps1`） |
| 被测二进制 | `examples/wsslserver` | **`bin/Release/quicsample`**（sample 工具，包含 server 和 client 模式） |
| 启动参数 | `127.0.0.1 4433 key cert --initial-pkt-num=0` | **`-server -cert_file:<cert> -key_file:<key> -listen:127.0.0.1 -port:4433`**（待确认） |
| 依赖库 | wolfssl, nghttp3 | **OpenSSL 3**（子模块自带）, libnuma, libatomic |
| QUIC 版本 | draft / v1 | **QUIC v1 / v2**（RFC 9000 / RFC 9369） |
| 子模块 | 无 | **有**（深度递归：`git submodule update --init --recursive`） |
| 特殊构建需求 | 无 | **PowerShell (pwsh)** 可选；纯 CMake 也可构建 |

---

## 3. 源码获取与 Patch 策略

### 3.1 checkout 函数

**需要获取的仓库：**

1. **msquic** — `https://github.com/microsoft/msquic.git`
   - 基线版本：**`v2.5.7-rc`**（commit `f25f432`，2026-01-16，最新预发布版，含虚拟缓冲区修复等改进）
   - ft-net-quicfuzzer 中使用的旧版本 `a933f7b7` 过于陈旧
   - 获取后执行 `git submodule update --init --recursive`（包含 opensslquic 等子模块）
2. **OpenSSL 3（opensslquic）** — msquic 子模块自带，无需单独克隆
   - 通过 `git submodule update --init --recursive` 自动获取

使用 `.git-cache/` 缓存克隆结果，`repo/` 存放工作副本（与 ngtcp2 保持一致）。

### 3.2 Patch — 随机数固定与时间固定

**目标：** 使 fuzzing 过程中的随机数和时间具有确定性，从而提高 fuzzer 的可复现性和效率。

**待办：实现前需先在 msquic v2.5.6 和其内置 OpenSSL 3 源码中实际排查以下两类接口的所有调用点，确认需要 patch 的确切位置。**

#### (a) 随机数固定 — 需排查的接口

**OpenSSL 3 侧（opensslquic 子模块）：**
- `RAND_bytes()` / `RAND_bytes_ex()` — 主要密码学随机数接口
- `RAND_priv_bytes()` / `RAND_priv_bytes_ex()` — 私有随机数
- `RAND_seed()` / `RAND_add()` — 随机数池注入
- OpenSSL 3 的 DRBG provider 机制（`EVP_RAND` 相关）

**msquic 侧：**
- `CxPlatRandom()` — msquic 平台抽象层的随机数接口（`src/platform/`）
- Linux 下可能直接调用 `getrandom()` / `/dev/urandom` / `arc4random()`
- Connection ID 生成、重试令牌、地址验证 token 等场景的随机数
- `QUIC_RANDOM` 相关结构和函数

**排查方法：**
```bash
# msquic 自身的随机数调用
rg -n 'CxPlatRandom|RAND_bytes|rand\(|random\(|getrandom|getentropy|/dev/urandom|arc4random' src/
# OpenSSL 子模块的 RAND 实现
rg -n 'RAND_bytes|RAND_priv_bytes' submodules/openssl/crypto/
```

**参考思路：** `subjects/QUIC/ngtcp2/wolfssl-random.patch` 的方式——在最底层随机数生成函数中检查 `FAKE_RANDOM` 环境变量，存在时用 `rand_r()` + 固定种子替代。对 msquic 而言，可能需要同时 patch `CxPlatRandom()` 和 OpenSSL 的 `RAND_bytes()`。

#### (b) 时间固定 — 需排查的接口

**msquic 侧：**
- `CxPlatTimeUs64()` / `CxPlatGetTimerResolution()` — msquic 平台抽象层的时间接口
- `clock_gettime()` / `gettimeofday()` / `time()` 的直接调用
- `src/platform/platform_posix.c` 中的时间实现
- 连接空闲超时、握手超时等的计时逻辑

**OpenSSL 3 侧：**
- 证书验证中的时间检查（`X509_verify_cert` → `time()` / `X509_cmp_time`）
- TLS session ticket 过期检查
- `OSSL_TIME` 相关接口（OpenSSL 3 新增的时间抽象）

**排查方法：**
```bash
# msquic 时间相关
rg -n 'CxPlatTime|clock_gettime|gettimeofday|time\(|CLOCK_MONOTONIC|CLOCK_REALTIME' src/
# OpenSSL 时间相关
rg -n 'time\(|X509_cmp_time|OSSL_TIME' submodules/openssl/crypto/ submodules/openssl/include/
```

**参考思路：** `subjects/QUIC/ngtcp2/quicfuzz-ngtcp2.patch` 的方式——首次调用时读取 `FAKE_TIME` 环境变量解析为基准时间，后续返回 `fake_base + (real_now - real_base)`。

#### (c) Patch 策略原则

- **尽量在最底层 patch**：msquic 有清晰的平台抽象层（`CxPlat*`），优先 patch 该层
- **环境变量控制**：所有 patch 均通过 `FAKE_RANDOM` / `FAKE_TIME` 环境变量开关
- **保持时间单调性**：fake time 必须单调递增
- **版本适配**：patch 必须针对 msquic v2.5.7-rc 及其内置 opensslquic 的实际代码编写

---

## 4. 函数实现计划

### 4.1 `install_dependencies`

```bash
sudo apt-get install -y cmake libnuma-dev powershell
```

PowerShell (pwsh) 是 msquic 官方构建脚本所需，但纯 CMake 构建也可行。如果 Docker 环境中已有 pwsh 则直接使用，否则用纯 CMake 方式。

### 4.2 `build_aflnet`

**流程：**

1. 创建 `target/aflnet/` 目录，拷贝 `repo/msquic`
2. **编译 msquic（AFL 插桩）：**
   - 方式 A — 使用 PowerShell 脚本：
     ```
     CC=${HOME}/aflnet/afl-clang-fast CXX=${HOME}/aflnet/afl-clang-fast++ \
     AFL_USE_ASAN=1 \
     pwsh -Command ./scripts/build.ps1 -Tls openssl3 -Clang -Static -Config Release -Clean -Parallel $(nproc)
     ```
   - 方式 B — 使用纯 CMake：
     ```
     CC=${HOME}/aflnet/afl-clang-fast CXX=${HOME}/aflnet/afl-clang-fast++
     cmake -G 'Unix Makefiles' -DQUIC_BUILD_TOOLS=ON -DQUIC_BUILD_SHARED=OFF \
           -DCMAKE_C_FLAGS="-g -O2 -fsanitize=address" \
           -DCMAKE_CXX_FLAGS="-g -O2 -fsanitize=address" ..
     cmake --build .
     ```
   - OpenSSL 3 由 msquic 的 CMake 自动从子模块编译
3. 验证 `bin/Release/quicsample` 已生成

**参考：** ft-net-quicfuzzer 的 `build_consumer` 函数。

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
       -- bin/Release/quicsample -server \
       -cert_file:<cert> -key_file:<key> \
       -listen:127.0.0.1 -port:4433
   ```
   **注意：** quicsample 的确切命令行参数需在实际源码中确认。
3. 覆盖率收集（使用 gcov 目标 + `compute_coverage` + `gcovr`）

**关键参数说明：**
- `-N "udp://127.0.0.1/4433 "` — UDP 协议的网络地址
- `-P NOP` — 协议类型为 NOP（QUIC 没有 AFLNet 原生的协议解析器）
- quicsample 的 server 模式参数需要查看 `src/tools/sample/sample.c` 确认

### 4.4 `build_sgfuzz`

**流程：**

1. 创建 `target/sgfuzz/` 目录，拷贝 `repo/msquic`
2. **SGFuzz 插桩 msquic：**
   - `CC=clang CXX=clang++`
   - `CFLAGS="-g -O3 -fsanitize=address -fsanitize=fuzzer-no-link -DSGFUZZ -v -Wno-int-conversion"`
   - `python3 ${HOME}/sgfuzz/sanitizer/State_machine_instrument.py .`
3. **CMake 编译：**
   ```
   cmake -G 'Unix Makefiles' -DQUIC_BUILD_TOOLS=ON -DQUIC_BUILD_SHARED=OFF ..
   cmake --build .
   ```
4. **手动链接最终二进制（关键步骤）：**
   ft-net-quicfuzzer 中使用了手动 clang 链接：
   ```
   cd src/tools/sample
   clang -o ../../../bin/Release/quicsample \
       -fsanitize=address -DSGFUZZ -lstdc++ -fsanitize=fuzzer \
       CMakeFiles/quicsample.dir/sample.c.o \
       ../../../bin/Release/libmsquic.a \
       ../../../obj/Release/libplatform.a \
       ../../../_deps/opensslquic-build/openssl/lib/libssl.a \
       ../../../_deps/opensslquic-build/openssl/lib/libcrypto.a \
       -ldl -latomic -lnuma -lpthread -lrt -lm -lresolv \
       -lsFuzzer -lhfnetdriver -lhfcommon
   ```
   **注意：** 具体 .o 和 .a 文件路径需根据 v2.5.7-rc 的构建输出确认。

**参考：** ft-net-quicfuzzer 的 `build_consumer_sgfuzz` 函数。

### 4.5 `run_sgfuzz`

**流程：**

1. 设置环境变量：
   - `ASAN_OPTIONS`, `AFL_NO_AFFINITY=1`, `FAKE_RANDOM=1`, `FAKE_TIME`
   - `HFND_TCP_PORT=4433`（honggfuzz netdriver 端口）
2. 运行 libfuzzer 模式：
   ```
   ./quicsample <SGFuzz_ARGS> -- -server -cert_file:<cert> -key_file:<key> \
       -listen:127.0.0.1 -port:4433
   ```
   SGFuzz_ARGS 包括：`-max_len=100000 -close_fd_mask=3 -shrink=1 -reload=30 -print_final_stats=1 -detect_leaks=0 -max_total_time=$timeout -artifact_prefix=...`
3. 排序语料 + 覆盖率收集

### 4.6 `build_ft_generator`

**流程（ngtcp2 客户端作为 generator）：**

FT 模式下，generator 是 **ngtcp2 的 QUIC 客户端**（与 ft-net-quicfuzzer 一致），consumer/sink 是 msquic 的 `quicsample`。

1. 创建 `target/ft/generator/` 目录
2. 编译 wolfssl（供 ngtcp2 使用）
3. 编译 nghttp3
4. **编译 ngtcp2（FT generator 插桩）：**
   - `CC=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast`
   - `FT_CALL_INJECTION=1`, `FT_HOOK_INS=branch,load,store,select,switch`
   - autotools 编译，产出 `examples/wsslclient`

**注意：** generator 侧需要同时获取和编译 ngtcp2 + wolfssl + nghttp3（可复用 `subjects/QUIC/ngtcp2/` 的 checkout 逻辑）。

### 4.7 `build_ft_consumer`

**流程（msquic 作为 consumer/sink）：**

1. 创建 `target/ft/consumer/` 目录
2. **编译 msquic（AFL++ consumer 插桩）：**
   - `CC=${AFL_PATH}/afl-clang-fast CXX=${AFL_PATH}/afl-clang-fast++`
   - `AFL_PATH=${HOME}/fuzztruction-net/consumer/aflpp-consumer`
   - `CFLAGS="-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"`
   - CMake 或 pwsh 编译

### 4.8 `run_ft`

**流程：**

1. 合成 `ft.yaml` 配置文件：
   - 拼接 `ft-common.yaml` + `ft-source.yaml`（ngtcp2 客户端） + `ft-sink.yaml`（msquic 服务器）
2. 运行 FT：
   ```
   sudo fuzztruction --log-level info ft.yaml fuzz -t ${timeout}s
   ```
3. 收集覆盖率

**注意：** ft-net-quicfuzzer 中没有现成的 msquic FT yml 配置，需要从零创建。

### 4.9 `build_gcov`

**流程：**

1. 使用 `gcc/g++` + `CFLAGS="-fprofile-arcs -ftest-coverage"` 编译 msquic
2. CMake 方式编译，确保 `-DQUIC_BUILD_TOOLS=ON`
3. 产出的 `bin/Release/quicsample` 可用于覆盖率收集

### 4.10 `replay`

**流程：**

1. 启动 gcov 版 `quicsample`（带 `LD_PRELOAD=libgcov_preload.so`）
2. 使用 `aflnet-replay` 回放测试用例到 UDP 端口 4433
3. 等待完成后 kill 服务器

---

## 5. 需要创建的 YAML 配置文件

### 5.1 `ft-source.yaml`（FT generator — ngtcp2 客户端）

```yaml
source:
  bin-path: "/home/user/target/ft/generator/ngtcp2/examples/wsslclient"
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

### 5.2 `ft-sink.yaml`（FT consumer — msquic 服务器）

```yaml
sink:
  bin-path: "/home/user/target/ft/consumer/msquic/bin/Release/quicsample"
  env:
    - FAKE_RANDOM: "1"
    - FAKE_TIME: "2026-03-11 12:00:00"
  arguments:
    - "-server"
    - "-cert_file:/home/user/profuzzbench/cert/fullchain.crt"
    - "-key_file:/home/user/profuzzbench/cert/server.key"
    - "-listen:127.0.0.1"
    - "-port:4433"
  working-dir: "/home/user/target/ft/consumer/msquic"
  input-type: Udp
  output-type: Udp
  is-server: true
  server-port: "4433"
  send-sigterm: true
  log-stdout: true
  log-stderr: true
  allow-unstable-sink: true
  persistent-server: true

gcov:
  bin-path: "/home/user/target/gcov/msquic/bin/Release/quicsample"
  cwd: "/home/user/target/gcov/msquic/"
  env:
    - LD_PRELOAD: "libgcov_preload.so"
    - FAKE_RANDOM: "1"
  src-dir: "/home/user/target/gcov/msquic"
  reporter: "gcovr"
```

**注意：** quicsample 的 server 模式命令行参数格式（`-cert_file:` vs `--cert-file` 等）需在 `src/tools/sample/sample.c` 源码中确认，v2.5.7-rc 可能与旧版不同。

---

## 6. 需要创建的种子文件

在 `subjects/QUIC/msquic/` 下创建：
- `seed/` — 原始 QUIC ClientHello 数据包（用于 SGFuzz / FT）
- `seed-replay/` — AFLNet 格式的 length-prefixed 种子（用于 AFLNet）

种子获取方式：使用 `init-seed-capture` skill，或手动：
1. 启动 msquic quicsample server
2. 用 ngtcp2 客户端或 msquic 自带 client 发起 QUIC 连接
3. tcpdump 抓取 client→server 的 UDP payload

---

## 7. 需要安装的额外依赖

```bash
# msquic 编译依赖
sudo apt-get install -y cmake libnuma-dev

# 可选：PowerShell（msquic 官方构建脚本需要，纯 CMake 可不装）
# sudo apt-get install -y powershell
```

OpenSSL 3 由 msquic 子模块自带，无需单独安装。

---

## 8. 实现顺序与里程碑

### Phase 1: 基础设施
- [ ] 编写 `checkout` 函数（克隆 msquic + 递归子模块，应用 patch）
- [ ] 编写 `install_dependencies` 函数
- [ ] 排查并创建 `msquic-random.patch`（OpenSSL 3 / CxPlatRandom 随机数固定）
- [ ] 排查并创建 `msquic-time.patch`（CxPlatTime / OpenSSL 3 时间固定）
- [ ] 确认 `quicsample` server 模式的确切命令行参数
- [ ] 编写 `build_gcov` 函数
- [ ] 编写 `replay` 函数
- [ ] 准备种子文件（`seed/` 和 `seed-replay/`）

### Phase 2: AFLNet
- [ ] 编写 `build_aflnet` 函数
- [ ] 编写 `run_aflnet` 函数
- [ ] 测试：短时间 fuzzing campaign 验证 AFLNet 可正常运行

### Phase 3: SGFuzz
- [ ] 编写 `build_sgfuzz` 函数（SGFuzz 插桩 + 手动链接 libfuzzer/hfnetdriver）
- [ ] 编写 `run_sgfuzz` 函数
- [ ] 测试：短时间 fuzzing campaign 验证 SGFuzz 可正常运行

### Phase 4: Fuzztruction (FT)
- [ ] 编写 `build_ft_generator` 函数（ngtcp2 客户端 + FT 插桩）
- [ ] 编写 `build_ft_consumer` 函数（msquic + AFL++ 插桩）
- [ ] 创建 `ft-source.yaml` 和 `ft-sink.yaml`
- [ ] 编写 `run_ft` 函数
- [ ] 测试：短时间 fuzzing campaign 验证 FT 可正常运行

---

## 9. 最终效果

完成后，`subjects/QUIC/msquic/` 目录结构：

```
subjects/QUIC/msquic/
├── README.md              # 本文档
├── config.sh              # 标准化构建脚本（checkout/build_*/run_*/replay/build_gcov）
├── msquic-random.patch    # OpenSSL3 / CxPlatRandom 随机数确定性 patch
├── msquic-time.patch      # CxPlatTime / OpenSSL3 时间确定性 patch
├── ft-source.yaml         # FT generator 配置（ngtcp2 客户端）
├── ft-sink.yaml           # FT consumer 配置（msquic 服务器）
├── seed/                  # 原始 QUIC 种子
└── seed-replay/           # AFLNet 格式种子
```

可通过标准命令运行：

```bash
# 构建
./scripts/build.sh -t QUIC/msquic -f aflnet -v v2.5.7-rc
./scripts/build.sh -t QUIC/msquic -f sgfuzz -v v2.5.7-rc
./scripts/build.sh -t QUIC/msquic -f ft -v v2.5.7-rc

# Fuzzing
./scripts/run.sh -t QUIC/msquic -f aflnet -v v2.5.7-rc --times 1 --timeout 3600 -o output
./scripts/run.sh -t QUIC/msquic -f sgfuzz -v v2.5.7-rc --times 1 --timeout 3600 -o output
./scripts/run.sh -t QUIC/msquic -f ft -v v2.5.7-rc --times 1 --timeout 3600 -o output
```

---

## 10. 注意事项与风险

1. **递归子模块体积大** — msquic 的 `git submodule update --init --recursive` 会拉取 OpenSSL 等大型子模块，克隆时间和磁盘占用较高
2. **PowerShell vs 纯 CMake** — ft-net-quicfuzzer 的 `build_consumer` 用 `pwsh` 构建，Docker 环境中 pwsh 未必可用；应优先尝试纯 CMake 方式，如遇问题再考虑安装 pwsh
3. **SGFuzz 手动链接复杂** — ft-net-quicfuzzer 中的 SGFuzz 构建需要手动指定大量 .o / .a 文件路径进行最终链接，路径在 v2.5.6 中可能已变化，需实际编译后确认
4. **FT 无现成配置** — ft-net-quicfuzzer 中没有 msquic 的 FT yml 配置文件，需要从零创建并调试 server-ready-on 信号
5. **quicsample 参数格式** — msquic 的 quicsample 命令行参数使用 `-key:value` 格式（而非 `--key value`），具体参数需查看 `src/tools/sample/sample.c` 源码
6. **OpenSSL 3 内置** — msquic 通过子模块自带 OpenSSL 3，不使用系统 OpenSSL，patch 需要应用到子模块内的代码
7. **平台抽象层** — msquic 有清晰的 `CxPlat*` 平台抽象层（`src/platform/`），随机数和时间的 patch 应优先在此层处理，可能比直接 patch OpenSSL 更简洁
8. **UDP vs TCP** — msquic 是 QUIC 协议（UDP），AFLNet 需要 `udp://` netinfo
