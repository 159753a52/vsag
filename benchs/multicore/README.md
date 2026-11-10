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
| final | `d5108431`（已含 #3014）+ #3304 预取默认值 + #3302 visit/候选堆 + #3303 SQ8 四路 L2 |

## 分步使用

```bash
cd benchs/multicore
bash prepare_data.sh                       # 或只准备部分数据集：prepare_data.sh gist sift
bash build_variant.sh base a2baa8fb        # 名称 + 基准提交 + 要 cherry-pick 的提交
bash build_variant.sh final d5108431 136b783e 18dc9179 175a922a 54c268e9
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

## 测量方法

- **配置**：HGraph，ODescent 建图，`max_degree=32`、`ef_construction=300`、`alpha=1.2`；基础编码为 RaBitQ 或 SQ8，FP32 精排，`topk=10`。`ef_search` 按基线召回率约 0.90 选取，各版本相同，取值见 `config.sh`。
- **只读索引**：`eval_immutable.patch` 让评测工具在加载索引后调用 `SetImmutable()`，测的是只读检索场景。这处改动只用于测试。
- **绑核**：N 个线程绑到 N 个物理核，每核一个逻辑 CPU，避免 SMT 干扰。默认按“逻辑 CPU 2k 和 2k+1 是同一物理核”处理，先用 `lscpu -e` 确认；布局不同时设置 `PIN_STEP`。
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

在华为云 x2e.64u.128g（AMD Genoa，32 核 64 线程，1 个 NUMA 节点，4 个 L3 域，Ubuntu 24.04，GCC 13.3）上，final 相对 base 的 QPS 提升如下。所有配置召回率不变，达标的 5 组 P99 下降 16%～23%。

| 配置 | 1 线程 | 4 线程 | 8 线程 | 16 线程 | 32 线程 |
| --- | --- | --- | --- | --- | --- |
| GIST RaBitQ | +28.9% | +26.8% | +24.3% | +24.1% | +23.6% |
| SIFT RaBitQ | +25.1% | +22.0% | +21.9% | +21.0% | +21.9% |
| Cohere RaBitQ | +22.5% | +21.7% | +21.6% | +22.4% | +20.3% |
| OpenAI RaBitQ | +21.3% | +21.6% | +18.1% | +18.4% | +19.0% |
| SIFT SQ8 | +17.7% | +17.8% | +18.4% | +18.6% | +16.7% |
| GIST SQ8 | +15.8% | +13.7% | -2.8% | -2.8% | -0.8% |
| Cohere SQ8 | +1.5% | +1.6% | +0.8% | +0.5% | +1.4% |

GIST、Cohere 的 SQ8 编码为 768～960 字节，8 线程以上受单个 L3 域的内存带宽限制。用 `placement.sh` 把线程分散到 4 个 L3 域后，GIST SQ8 在 8 线程的提升为 +16.9%。

## 注意事项

- 服务器访问 GitHub 不稳定时，可以在别处下载 `extern/` 里固定版本的依赖包，用 `VSAG_THIRDPARTY_<DEP>` 指向本地 HTTP 地址。
- 透明大页保持默认的 `madvise`。改成 `always` 后 SQ8 会变慢 5%～11%。
- `perf_diagnose.sh` 的事件名针对 AMD Zen 4，其他 CPU 需要改 `EVENTS`。虚拟机里通常没有 IBS 和非核心计数器，`perf mem` 和 `perf c2c` 无法使用。
