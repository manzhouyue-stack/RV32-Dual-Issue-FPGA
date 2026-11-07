# RV32 双发射处理器与终端游戏机：提交代码

紫光同创 选题一。板卡 MES2L676-100HP（PG2L100H-6FBG676）。

本目录的 RTL 与实板验证通过的冻结工程逻辑相同，只增加了注释。

## 目录
| 目录 | 内容 |
|---|---|
| `project/source/cpu` | CPU：`rv32_core_d.sv`（双发射核）、译码、ALU、位操作、CSR、寄存器堆 |
| `project/source` | SoC：TCM、Cache、DDR 桥、MMIO、UART、顶层 |
| `project/ip` | PLL、RAM、DDR3 控制器（厂商 IP） |
| `project/soc_stage1.fdc`、`ddr3_test.rcf`、`soc_stage1.pds` | 约束、布线约束、PDS 工程 |
| `firmware` | CoreMark、系统测试、贪吃蛇、构建脚本 `build.sh` |
| `sim` | XSim 测试平台 `run_sim.py`、指令集回归 `isa/run_isa.py` |
| `tools` | 生成构建目录、PDS 构建、串口采集、贪吃蛇客户端、ILA 与资源分析 |

## 环境
- PDS 2023.2-SP3
- Vivado 2021.1 XSim，只用于 RTL 仿真；路径不同时设置 `XILINX_VIVADO`
- riscv32-unknown-elf-gcc 13.2.0；路径不同时设置 `RISCV_BIN`
- Python 3，串口工具需要 pyserial

## 构建
生成固件（Linux 或 WSL，目标有 `perf`、`val`、`perf1`、`snake`、`snake_sim`、`systest`）：
```bash
bash firmware/build.sh perf
```
生成位流（Windows PowerShell）。短路径更稳妥，固件位于 RAM 初值中，换固件要重新生成：
```bash
python tools/make_app_build.py firmware/images/perf C:/FPGA/build_perf
```
```bash
powershell -File tools/pds_build.ps1 -Dir C:/FPGA/build_perf
```
RTL 仿真：
```bash
python sim/run_sim.py coremark firmware/images/perf1
```
指令集回归（在 `sim/isa` 目录运行）：
```bash
python run_isa.py --dual --m --b --suite=rv32um
```

## 运行
串口 115200 8N1。下载位流后按 KEY0 复位。

- **CoreMark：** 约 12.6 秒后输出结果，只亮 LED0。成绩按原始 ticks 计算，不用打印的整数秒结果。
- **贪吃蛇：** `python tools/snake_term.py COM5 snake.log`，然后按 KEY0。按键：方向键或 wasd 移动，`n` 新局，`o` 自动驾驶，`p` 或 KEY1 暂停，`r` 回放，`f` 触发异常。

## 已知限制
- v1.1 位流有 DDR3 IP 内部 hold 违例（快角 -0.354 ns，慢角 -0.181 ns），CPU 时钟域满足时序。
- 未实现可选的 PMP，rv32mi 的 pmpaddr 不通过。
- `project` 默认 RAM 初值为 CoreMark 性能版固件。
