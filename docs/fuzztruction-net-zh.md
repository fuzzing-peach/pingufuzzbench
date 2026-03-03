# Fuzztruction-Net 文档

## 概述

Fuzztruction-Net 是一个学术原型的网络协议模糊测试工具。与传统模糊测试工具直接变异发送到目标应用的输入消息不同，它采用**故障注入**的创新方法。

核心原理：
1. 选取两个通信对等体（peer）中的一个作为 "weird peer"
2. 向 weird peer 注入故障，迫使它产生异常输出
3. 目标对等体（target peer）接收到异常消息，可能触发漏洞
4. 由于 weird peer 保留了完整的加密/签名能力，可以正确处理协议状态

## 项目结构

```
fuzztruction-net/
├── Cargo.toml                 # Rust workspace 配置
├── README.md                  # 项目说明
├── ft.yaml                    # FT-Net 通用配置模板
├── target/                    # 构建产物目录
│   ├── debug/                # Debug 构建
│   └── release/              # Release 构建
├── generator/                # Generator (weird peer) 相关
│   ├── agent/               # JIT 引擎，运行时注入故障
│   └── pass/                # LLVM pass，插入 patch points
├── consumer/                 # Consumer (target peer) 相关
│   └── aflpp-consumer/      # AFL++ 编译器用于覆盖率反馈
├── lib/                     # 共享库
│   ├── jail/                # 进程沙箱
│   ├── proc-maps/           # 进程内存解析
│   └── compute_coverage/    # 覆盖率计算
├── scheduler/               # 模糊测试调度器
├── env/                     # Docker 环境管理脚本
│   ├── build.sh            # 构建 Docker 镜像
│   ├── pull-prebuilt.sh    # 拉取预构建镜像
│   ├── start.sh            # 启动容器
│   └── stop.sh             # 停止容器
└── fuzztruction-experiments/ # 实验配置和目标
```

## 核心组件

### 1. Scheduler（调度器）
- 协调 weird peer 和 target peer 的交互
- 管理模糊测试循环和维护队列
- 每个队列条目包含：种子输入 + 应用的故障

### 2. Weird Peer（故障生成器）
作为种子生成器，为目标生成定制输入。

**Compiler Pass** (`generator/pass/`):
- 使用 LLVM patch points 插桩目标代码
- Patch points 位置记录在编译后二进制文件的独立 section 中
- 调度器选择要攻击的 patch point，agent 负责实际注入

**Agent** (`generator/agent/`):
- 运行在 weird peer 上下文中
- 实现 forkserver 功能
- 通过 JIT 引擎实时变异代码
- 与调度器通过共享内存和消息队列通信

### 3. Consumer（目标）
- 待测试的目标应用
- 使用 AFL++ 编译器编译以记录覆盖率反馈
- 覆盖率信息指导 weird peer 的故障选择

## 使用步骤

### 环境准备

```bash
# 克隆仓库（需放置在用户主目录）
git clone --recurse-submodules https://github.com/fuzztruction/fuzztruction-net.git
cd fuzztruction-net

# 方式1：拉取预构建镜像（推荐用于复现论文实验）
./env/pull-prebuilt.sh

# 方式2：本地构建运行时环境
./env/build.sh

# 启动容器
./env/start.sh
# 再次执行进入容器 shell
./env/start.sh
```

### 构建 Fuzztruction-Net

在容器内：
```bash
cd /home/user/fuzztruction
cargo build                    # Debug 构建
# 或
cargo build --release          # Release 构建
```

关键构建产物：
| 产物 | 用途 |
|------|------|
| `./generator/pass/fuzztruction-source-llvm-pass.so` | LLVM pass，插入 patch points |
| `./generator/pass/fuzztruction-source-clang-fast` | weird peer 编译器 wrapper |
| `./target/debug/libgenerator_agent.so` | 注入 weird peer 的 agent |
| `./target/debug/fuzztruction` | 主模糊测试二进制 |

### 目标配置格式

FT-Net 使用 YAML 配置文件定义目标和配置。配置由三部分组成：

#### 1. 通用配置（ft.yaml）
```yaml
work-directory: "/tmp/fuzzing-output"   # 工作目录
input-directory: "/home/user/no-inputs" # 输入目录
jail-uid: 1000                          # 进程沙箱 UID
jail-gid: 1000                          # 进程沙箱 GID
```

#### 2. Source 配置（ft-source.yaml）- Generator
```yaml
source:
  bin-path: "/home/user/target/ft/generator/dcmtk/build/bin/dcmsend"
  env:
    - DCMDICTPATH: /home/user/profuzzbench/subjects/DICOM/dcmtk/dicom.dic
  arguments:
    - "-aet"
    - "YOU_AET"
    - "-aec"
    - "ANY-SCP"
    - "127.0.0.1"
    - "5158"
    - /home/user/profuzzbench/subjects/DICOM/dcmtk/dcm-files/image-00000.dcm
  input-type: Tcp           # 输入类型：Tcp/Udp/Stdout/Stdin
  output-type: Tcp          # 输出类型
  is-server: false          # 是否为服务器端
  log-stdout: true          # 记录 stdout
  log-stderr: true          # 记录 stderr
```

#### 3. Sink 配置（ft-sink.yaml）- Consumer
```yaml
sink:
  bin-path: "/home/user/target/ft/consumer/dcmtk/build/bin/dcmqrscp"
  env:
    - DCMDICTPATH: /home/user/profuzzbench/subjects/DICOM/dcmtk/dicom.dic
  arguments:
    [
      "--single-process",
      "--config",
      "/home/user/profuzzbench/subjects/DICOM/dcmtk/dcmqrscp.cfg",
      "-d"
    ]
  input-type: Tcp
  output-type: Tcp
  is-server: true
  server-port: "5158"
  log-stdout: true
  log-stderr: true
  allow-unstable-sink: true  # 允许目标不稳定
  send-sigterm: true         # 使用 SIGTERM 而非 SIGKILL

gcov:
  bin-path: "/home/user/target/gcov/consumer/dcmtk/build/bin/dcmqrscp"
  cwd: "/home/user/target/gcov/consumer/dcmtk"
  src-dir: "/home/user/target/gcov/consumer/dcmtk"
  reporter: gcovr
```

### 构建目标

```bash
# 构建 Generator (weird peer)
export FT_CALL_INJECTION=1
export FT_HOOK_INS=call,branch,load,store,select,switch
export CC=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast
export CXX=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast++
export CFLAGS="-O0 -g -DFT_FUZZING -DFT_GENERATOR"
export CXXFLAGS="-O0 -g -DFT_FUZZING -DFT_GENERATOR"

mkdir build && cd build
cmake ..
make

# 构建 Consumer (target peer)
export AFL_PATH=${HOME}/fuzztruction-net/consumer/aflpp-consumer
export CC=${AFL_PATH}/afl-clang-fast
export CXX=${AFL_PATH}/afl-clang-fast++
export CFLAGS="-fsanitize=address -O3 -g -DFT_FUZZING -DFT_CONSUMER"
export CXXFLAGS="-fsanitize=address -O3 -g -DFT_FUZZING -DFT_CONSUMER"

mkdir build && cd build
cmake ..
make
```

### 运行模糊测试

#### 基准测试
```bash
# Debug 构建
sudo ./target/debug/fuzztruction ./config.yml --purge --log-output benchmark -i 25

# Release 构建
sudo ./target/release/fuzztruction ./config.yml --purge --log-output benchmark -i 25
```

#### 开始模糊测试
```bash
# Debug 构建
sudo ./target/debug/fuzztruction ./config.yml fuzz -j 10 -t 10m

# Release 构建
sudo ./target/release/fuzztruction ./config.yml fuzz -j 10 -t 10m
```

参数说明：
- `-j 10`: 使用 10 个核心
- `-t 10m`: 超时时间 10 分钟
- `--purge`: 清除已有工作目录
- `--log-output`: 记录输出到文件

### 收集覆盖率

```bash
sudo ./target/release/fuzztruction ft.yaml gcov -t 3s
```

## 与 PinguFuzzBench 集成

在 `subjects/PROTOCOL/IMPLEMENTATION/config.sh` 中：

```bash
function build_ft_generator {
    mkdir -p target/ft/generator
    rm -rf target/ft/generator/*
    cp -r repo/openssl target/ft/generator/openssl
    pushd target/ft/generator/openssl >/dev/null

    export FT_CALL_INJECTION=1
    export FT_HOOK_INS=call,branch,load,store,select,switch
    export CC=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast
    export CXX=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast++
    export CFLAGS="-O0 -g -DFT_FUZZING -DFT_GENERATOR"
    export CXXFLAGS="-O0 -g -DFT_FUZZING -DFT_GENERATOR"

    mkdir build && cd build
    cmake ..
    make ${MAKE_OPT}

    popd >/dev/null
}

function build_ft_consumer {
    mkdir -p target/ft/consumer
    rm -rf target/ft/consumer/*
    cp -r repo/openssl target/ft/consumer/openssl
    pushd target/ft/consumer/openssl >/dev/null

    export AFL_PATH=${HOME}/fuzztruction-net/consumer/aflpp-consumer
    export CC=${AFL_PATH}/afl-clang-fast
    export CXX=${AFL_PATH}/afl-clang-fast++
    export CFLAGS="-fsanitize=address -O3 -g -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-fsanitize=address -O3 -g -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"

    mkdir build && cd build
    cmake ..
    make ${MAKE_OPT}

    popd >/dev/null
}

function run_ft {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    work_dir=/tmp/fuzzing-output

    # 生成 FT 配置
    temp_file=$(mktemp)
    sed -e "s|WORK-DIRECTORY|${work_dir}|g" \
        -e "s|UID|$(id -u)|g" \
        -e "s|GID|$(id -g)|g" \
        ${HOME}/profuzzbench/ft.yaml >"$temp_file"
    cat "$temp_file" >ft.yaml
    printf "\n" >>ft.yaml
    rm "$temp_file"
    cat ${HOME}/profuzzbench/subjects/PROTOCOL/IMPL/ft-source.yaml >>ft.yaml
    cat ${HOME}/profuzzbench/subjects/PROTOCOL/IMPL/ft-sink.yaml >>ft.yaml

    # 运行模糊测试
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction ft.yaml fuzz --log-level debug -t ${timeout}s

    # 收集覆盖率
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction ft.yaml gcov -t 3s
}
```

## 调试技巧

- `--log-output`: 记录 weird/target peer 的 stdout/stderr
- 在 YAML 的 sink 配置中设置 `AFL_DEBUG` 获取详细输出
- 检查命令参数是否正确（特别是 `LD_PRELOAD` 路径）
- 使用 `--purge` 重新运行

## 参考资料

- [论文 (BARS 2024)](https://mschchloegel.me/paper/bars2024fuzztructionnet.pdf)
- [GitHub 仓库](https://github.com/fuzztruction/fuzztruction-net)
