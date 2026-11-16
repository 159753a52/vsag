# HGraph 多核扩展性基准

这组脚本测量 HGraph 检索在 1、2、4、8、16、32 并发下的 QPS、P50/P99 延迟、召回率和扩展效率，用来对比两个版本的代码。对应 [antgroup/vsag#2883](https://github.com/antgroup/vsag/issues/2883) 的多核检索优化，报告里的数字都由这些脚本产出。

## 环境要求

- Linux x86_64，至少 32 个物理核；要复现 SQ8 四路计算的收益需要 AVX-512。
- 约 150 GB 磁盘：数据集约 15 GB，7 个索引和多个构建目录占其余部分。
- 编译 VSAG 的依赖（见 [DEVELOPMENT.md](../../DEVELOPMENT.md)）、`taskset`、`python3`。
- 准备 Cohere 和 OpenAI 数据集需要 Python 包 `numpy`、`pyarrow`、`h5py`。
- 做瓶颈分析需要 `perf`，并有 root 权限或 `perf_event_paranoid <= 0`。

所有产物放在 `$WORK`（默认 `~/vsag-multicore`），数据集放在 `$DATA_DIR`（默认 `$WORK/data`），两者都可以用环境变量改。

## 一键复现

```bash
bash benchs/multicore/reproduce.sh
```

它依次下载数据集、构建基线和最终版、建 7 个索引、跑完整的并发矩阵，最后把汇总写到 `$WORK/summary.txt`。在 32 核机器上要跑几个小时，中断后重跑会跳过已完成的步骤。两个版本是：

| 名称 | 代码 |
| --- | --- |
| base | `a2baa8fb`，#3014 合入前的官方 main |
| final | fork 分支 `bench/multicore-final`：`d5108431`（已含 #3014）+ #3304 预取默认值和长编码整条预取 + #3302 visit/候选堆 + #3303 SQ8 四路（L2 和内积）+ #3355 分块内存按 64 字节对齐 |

final 分支就是把这四个 PR 按顺序叠在 `d5108431` 上。#3302 和 #3304 都改了 `HGraph::elp_optimize`，叠的时候保留 #3304 的步长扫参写法，并按 #3302 去掉 visit 步长的扫参。

## 分步使用

```bash
cd benchs/multicore
bash prepare_data.sh                       # 或只准备部分数据集：prepare_data.sh gist sift
bash build_variant.sh base a2baa8fb        # 名称 + 基准提交 + 要 cherry-pick 的提交
git fetch https://github.com/159753a52/vsag.git +bench/multicore-final:refs/bench/final
bash build_variant.sh final refs/bench/final
bash bench.sh build gist-rabitq            # 用 base 建索引，所有版本共用这一份
bash bench.sh search final gist-rabitq 32  # 单次检索，输出一行结果
bash run_matrix.sh 3 "gist-rabitq" base final >> matrix.log
python3 summarize.py base final matrix.log
```

| 脚本 | 作用 |
| --- | --- |
| `config.sh` | 路径、7 组数据集和索引配置、绑核函数，其他脚本都会 source 它 |
| `prepare_data.sh` | 下载 GIST-960、SIFT-128（ann-benchmarks）和 Cohere-768、OpenAI-1536（VectorDBBench），后两者用 `convert_vdbbench.py` 转成 HDF5 |
| `build_variant.sh` | 为一个版本建 worktree，打上 `eval_immutable.patch`，Release 构建 `vsag` 和 `eval_performance` |
| `bench.sh` | 建索引，或用指定版本、线程数和 CPU 列表跑一次检索 |
| `run_matrix.sh` | 按轮次、配置、线程数跑完整矩阵，奇数轮正序、偶数轮逆序 |
| `summarize.py` | 取各轮中位数，输出相对基线的 QPS、P50、P99 变化、召回率差和扩展效率 |
| `perf_diagnose.sh` | 负载下采集 perf 计数器、PipelineL1/L2 和热点函数 |
| `placement.sh` | 对比线程集中绑核和分散到各 L3 域，判断是否受单个 L3 域的内存带宽限制 |

### 只测某一项改动

比较“加这一项”和“不加这一项”的两份代码，其余部分保持相同。例如单独测 #3355 的对齐：

```bash
git fetch https://github.com/antgroup/vsag.git +pull/3355/head:refs/bench/pr3355
bash build_variant.sh m0 680cb155                  # #3355 的基点
bash build_variant.sh mal 680cb155 refs/bench/pr3355~1..refs/bench/pr3355
bash run_matrix.sh 3 "sift-sq8 gist-rabitq" m0 mal >> align.log
python3 summarize.py m0 mal align.log
```

只测某一项时，数据集要选这一项会影响到的：SQ8 四路内积只影响 Cohere SQ8（cosine），长编码整条预取只影响 GIST、Cohere 的 SQ8（768～960 字节），对齐影响全部 7 组。

## 测量方法

- **配置**：HGraph，ODescent 建图，`max_degree=32`、`ef_construction=300`、`alpha=1.2`；基础编码为 RaBitQ 或 SQ8，FP32 精排，`topk=10`。`ef_search` 按基线召回率约 0.90 选取，各版本相同，取值见 `config.sh`。
- **只读索引**：`eval_immutable.patch` 让评测工具在加载索引后调用 `SetImmutable()`，测的是只读检索场景。这处改动只用于测试。
- **绑核**：N 个线程绑到 N 个物理核，每核一个逻辑 CPU，避免 SMT 干扰。默认按“逻辑 CPU 2k 和 2k+1 是同一物理核”处理，先用 `lscpu -e` 确认；布局不同时设置 `PIN_STEP`。
- **线程分布**：默认 `PLACEMENT=spread`，把线程均匀分到各个 L3 域，和不绑核时系统调度的结果一致。`PLACEMENT=packed` 先占满一个 L3 域（8 个核）再用下一个：编码较长的 SQ8 在 8、16 线程会被单个 L3 域的内存带宽卡住，测出的提升偏低，不代表实际部署的情况。
- **交替运行**：每轮内各版本交替执行，奇偶轮顺序相反，取各轮中位数，减少预热、温度和顺序带来的偏差。
- **查询量**：每个线程的查询数由 `QPT` 决定，单次检索约 10～45 秒。
- **扩展效率**：32 线程 QPS ÷（32 × 单线程 QPS），1.0 表示线性扩展。

`summarize.py` 的输出示例（QPS 提升达到 15% 的格子带 `*`）：

```text
== gist-rabitq ef=200 rounds=3 recall=0.9041
  th 1 QPS     1646 ->     2121  +28.9%* P50  -22.8%  P99 0.729->0.561  -23.0%  dRecall +0.00000
  ...
  th32 QPS    49064 ->    60620  +23.6%* P50  -19.5%  P99 0.838->0.669  -20.2%  dRecall +0.00000
  scaling eff 32: base 0.932 final 0.893
```

## 参考结果

在华为云 x2e.64u.128g（AMD Genoa，32 核 64 线程，1 个 NUMA 节点，4 个 L3 域，Ubuntu 24.04，GCC 13.3）上，final 相对 base 的 QPS 提升如下（`PLACEMENT=spread`，各版本交替跑 2 轮取平均，2026 年 11 月 14 日）。所有配置召回率不变，P99 延迟全部下降，降幅 7.6%～31.4%。

| 配置 | 1 线程 | 4 线程 | 8 线程 | 16 线程 | 32 线程 |
| --- | --- | --- | --- | --- | --- |
| GIST RaBitQ | +41.6% | +42.9% | +39.5% | +37.7% | +36.6% |
| SIFT RaBitQ | +26.7% | +27.3% | +23.9% | +25.2% | +23.2% |
| Cohere RaBitQ | +21.1% | +22.2% | +21.5% | +21.1% | +20.8% |
| OpenAI RaBitQ | +19.9% | +19.6% | +19.6% | +19.5% | +18.3% |
| SIFT SQ8 | +31.1% | +30.0% | +30.9% | +28.7% | +27.5% |
| GIST SQ8 | +31.3% | +28.1% | +29.7% | +25.5% | +7.6% |
| Cohere SQ8 | +21.0% | +23.8% | +21.9% | +19.3% | +9.7% |

这组数据测的代码和 final 分支的检索路径相同，final 分支后来只补了单测和一处检索参数的取值检查。

GIST、Cohere 的 SQ8 编码为 768～960 字节，32 线程时每个 L3 域的内存带宽已经用满，所以这一档提升较小。早期按 `PLACEMENT=packed` 测时，GIST SQ8 在 8、16 线程测出过 −2.8%，那是 8 个线程挤在同一个 L3 域造成的，现在默认的 `spread` 不会出现。

## 注意事项

- 服务器访问 GitHub 不稳定时，可以在别处下载 `extern/` 里固定版本的依赖包，用 `VSAG_THIRDPARTY_<DEP>` 指向本地 HTTP 地址。
- 透明大页保持默认的 `madvise`。改成 `always` 后 SQ8 会变慢 5%～11%。
- `perf_diagnose.sh` 的事件名针对 AMD Zen 4，其他 CPU 需要改 `EVENTS`。虚拟机里通常没有 IBS 和非核心计数器，`perf mem` 和 `perf c2c` 无法使用。
