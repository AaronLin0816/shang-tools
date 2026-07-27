# 火焰图生成脚本使用说明

本文档说明 `perf_flamegraph.sh` 的使用方式。该脚本用于对 `model` 可执行文件运行指定 RISC-V ELF 用例，并自动生成 `perf.data`、`perf report`、折叠栈文件和火焰图 SVG。

## 1. 使用路径

建议在仓库根目录执行脚本：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
bash tools/shang-tools/perf_flamegraph.sh <case-relative-path-or-absolute-path> [model extra args...]
```

脚本会从自身路径向上查找仓库根目录，因此从其他目录执行也可以，但从仓库根目录运行更容易检查输入用例和输出结果。

## 2. 最常用命令

使用默认测试用例目录下的相对路径：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
bash tools/shang-tools/perf_flamegraph.sh rv64ui/rv64ui-p-add.riscv
```

默认用例目录优先为：

```text
test/benchmarks/elfs/isa_cases
```

如果该目录不存在，脚本会回退到：

```text
test/benchmarks/elfs/isa_case
```

也可以直接传入 ELF 的绝对路径：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
bash tools/shang-tools/perf_flamegraph.sh /path/to/case/xxx.riscv
```

如果 `model` 还需要额外参数，放在用例路径后面即可，脚本会原样追加到 `model` 命令末尾：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
bash tools/shang-tools/perf_flamegraph.sh rv64ui/rv64ui-p-add.riscv --spike-params="--maxinsns=10000000"
```

## 3. 脚本默认行为

默认情况下，脚本会执行以下流程：

1. 检查 `perf`、`stackcollapse-perf.pl`、`flamegraph.pl` 是否可用。
2. 确保根目录 `CMakeLists.txt` 中的 Profile 编译参数包含 `-O3 -g -fno-omit-frame-pointer`。
3. 如果 `profile_build/model` 不存在，则以 Profile 模式构建 `model`。
4. 生成一个临时 runner，循环执行同一个用例 `RUNS` 次。
5. 使用 `perf record` 采样。
6. 生成 `perf.report.txt`、`perf.report.no-children.txt`、`perf.script`、`perf.folded.raw`、`perf.folded` 和 `flamegraph.svg`。

默认输出目录为：

```text
tools/shang-tools/perf-results/<timestamp>_<case-name>/
```

其中最常看的文件是：

```text
flamegraph.svg                 # 火焰图，浏览器打开
perf.report.txt                # 带 children 的 perf 文本报告
perf.report.no-children.txt    # self 开销视角的 perf 文本报告
perf.folded                    # 过滤后的折叠栈
perf.folded.raw                # 未过滤的原始折叠栈
run_case_<RUNS>x.sh            # 本次 perf 实际执行的 runner
```

## 4. 常用环境变量

所有参数都通过环境变量覆盖，写在命令前即可：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
RUNS=20 PERF_FREQ=499 bash tools/shang-tools/perf_flamegraph.sh rv64ui/rv64ui-p-add.riscv
```

构建相关参数：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `BUILD` | `1` | 是否在采样前检查/构建 Profile 版本；已有 `profile_build/model` 时会复用 |
| `BUILD_JOBS` | `10` | 默认 Profile 构建并行度 |
| `PROFILE_BUILD_DIR` | `<repo>/profile_build` | Profile 构建目录，也是脚本默认使用的 `model` 路径 |
| `USE_DOCKER_GCC15` | `1` | 默认构建时是否使用 `tools/shang-tools/docker-gcc15.sh` |
| `BUILD_CMD` | 空 | 自定义构建命令，非空时替代默认 CMake Profile 构建 |

用例和模型配置相关参数：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `CASE_DIR` | `test/benchmarks/elfs/isa_cases`，不存在时回退到 `test/benchmarks/elfs/isa_case` | 相对用例路径的前缀 |
| `RUNS` | `50` | 同一个用例在一次 perf 采样中的循环次数 |
| `ISA_MODEL_YAML` | `test/benchmarks/isa_model_config/ctest_isa_model.yaml` | 传给 `model` 的 `--isa-model-yaml` |
| `ISA_MODEL_BIN` | `test/benchmarks/isa_model_config/reset_rom_80000000.bin:0x1000` | 传给 `model` 的 `--isa-model-bin` |
| `RESULT_ROOT` | `tools/shang-tools/perf-results` | 输出目录根路径 |

perf 和火焰图相关参数：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `PERF_BIN` | `perf` | perf 命令路径 |
| `PERF_FREQ` | `997` | 采样频率 |
| `PERF_EVENT` | `cycles:u` | 采样事件；默认只看用户态 cycles |
| `PERF_CALLGRAPH` | `dwarf,8192` | 调用栈采集方式 |
| `PERF_REPORT_ARGS` | `--no-inline` | 追加给 `perf report` 的参数 |
| `PERF_SCRIPT_ARGS` | `--no-inline` | 追加给 `perf script` 的参数 |
| `FLAMEGRAPH_DIR` | 自动查找 `tools/FlameGraph` 等路径 | 指定包含 `stackcollapse-perf.pl` 和 `flamegraph.pl` 的目录 |

折叠栈过滤相关参数：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `PERF_DROP_POLLUTED_STACKS` | `1` | 是否启用折叠栈过滤 |
| `PERF_COMM_FILTER` | `model` | 只保留 command 名称为该值的栈；设为空可关闭 |
| `PERF_DROP_STARTUP_STACKS` | `1` | 是否过滤动态链接器、全局初始化、退出清理等启动/退出栈 |
| `PERF_DROP_MODEL_INIT_STACKS` | `1` | 是否过滤 model 初始化、YAML/JSON 解析、decoder 建表等初始化栈 |
| `PERF_MAX_STACK_DEPTH` | `256` | 超过该深度的异常栈会被丢弃 |
| `PERF_TRIM_STACK_DEPTH` | `32` | 火焰图中保留的最大栈深度；设为 `0` 表示不裁剪 |
| `PERF_MAX_UNKNOWN_RUN` | `8` | 连续 `[unknown]` 超过该值时认为该栈不可信并丢弃 |

## 5. 测试用例变化时优先改哪些参数

如果测试用例目录变化，优先改 `CASE_DIR`：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
CASE_DIR=/path/to/new/isa_case bash tools/shang-tools/perf_flamegraph.sh rv64model/xxx.riscv
```

如果用例不是默认 reset ROM 或默认 ISA model 配置，优先改 `ISA_MODEL_YAML` 和 `ISA_MODEL_BIN`：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
ISA_MODEL_YAML=/path/to/config.yaml \
ISA_MODEL_BIN=/path/to/reset_rom.bin:0x1000 \
bash tools/shang-tools/perf_flamegraph.sh rv64ui/rv64ui-p-add.riscv
```

如果用例很短，初始化开销容易淹没热点，优先增大 `RUNS`，并保持 `PERF_DROP_MODEL_INIT_STACKS=1`：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
RUNS=200 bash tools/shang-tools/perf_flamegraph.sh rv64ui/rv64ui-p-add.riscv
```

如果想观察初始化、配置加载、decoder 建表等一次性开销，关闭初始化栈过滤：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
PERF_DROP_MODEL_INIT_STACKS=0 bash tools/shang-tools/perf_flamegraph.sh rv64ui/rv64ui-p-add.riscv
```

如果用例很长，单次运行已经足够稳定，可以降低 `RUNS`，减少总采样时间：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
RUNS=1 bash tools/shang-tools/perf_flamegraph.sh /path/to/long_case.riscv
```

如果火焰图里有大量 `[unknown]` 或调用栈断裂，优先尝试调整调用栈采集方式：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
PERF_CALLGRAPH=fp bash tools/shang-tools/perf_flamegraph.sh rv64ui/rv64ui-p-add.riscv
```

如果需要更完整地检查异常栈，可以先关闭过滤和裁剪，对比 `perf.folded.raw` 与火焰图：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
PERF_DROP_POLLUTED_STACKS=0 PERF_TRIM_STACK_DEPTH=0 \
bash tools/shang-tools/perf_flamegraph.sh rv64ui/rv64ui-p-add.riscv
```

如果 profiling 的进程名不是 `model`，或者 `perf.folded` 为空，检查 `PERF_COMM_FILTER`。可以先设为空关闭 command 过滤：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
PERF_COMM_FILTER= bash tools/shang-tools/perf_flamegraph.sh rv64ui/rv64ui-p-add.riscv
```

## 6. 结果查看建议

先打开：

```text
tools/shang-tools/perf-results/<timestamp>_<case-name>/flamegraph.svg
```

火焰图宽度表示采样占比，不表示调用顺序。定位热点时通常按以下顺序看：

1. 先看最宽的顶层或中上层函数，判断热点属于 fetch/decode、MMU、memory、CSR、device、host 交互还是初始化。
2. 再看 `perf.report.txt`，确认 children 视角下的聚合热点。
3. 最后看 `perf.report.no-children.txt`，确认 self 开销是否集中在某些函数内部。

## 7. 常见问题

`perf` 没有权限时，需要在运行机器上调整 perf 权限或使用具备权限的账号执行。

如果 `flamegraph.svg` 为空，优先检查：

1. `perf.report.txt` 是否有采样。
2. `perf.folded.raw` 是否有内容。
3. `perf.folded` 是否因为 `PERF_COMM_FILTER` 或过滤规则被清空。

如果脚本找不到 FlameGraph 工具，可以显式指定：

```bash
cd /work/home/shang-chi/workspace/suncheek/model
FLAMEGRAPH_DIR=/path/to/FlameGraph bash tools/shang-tools/perf_flamegraph.sh rv64ui/rv64ui-p-add.riscv
```

