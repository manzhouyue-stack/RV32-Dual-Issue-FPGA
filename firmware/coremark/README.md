# CoreMark 计时器接入与首轮校验包

当前交付是预置镜像方案，不依赖 loader。CPU 保持 rv32_core_b v0.4，RESET_PC=0；复位夹具从 0 跳到应用 0x1000。

## 硬件前提

只适用于 B 新增计时器后的系统：LO=0x10003000、HI=0x10003004、HZ=0x10003008。系统和 timer 均 50 MHz。现有 v0.3 位流没有这些地址，访问会故障停机。

计数器接受请求时采样，stall/freeze 仍递增，无读副作用。驱动 high-low-high 重试，所有 tick 保留 uint64_t。测试模型与厂商实际 IP/实板严格区分。

## 源码与布局

upstream-lock.json 固定官方仓库提交及逐文件 SHA256。upstream 中算法及头文件保持官方字节原样，barebones 文件仅供参考，不参与编译。原有 C START v0.2 不修改。

RV32I/ILP32，-O2，关闭小数据及链接松弛，不使用 M/C/F/CSR。软件乘除来自工具链 libgcc，最终 ELF 审查是否存在不支持指令。-fno-delete-null-pointer-checks 用于裸机地址零语义，避免 GCC 在官方链表代码中生成 ebreak。

BOOT=0..0xfff，应用 ITCM=0x1000..0x7fff（含 .data LMA），DTCM=0x10000..0x17fff。栈顶 0x18000，预留 4 KiB 栈；这是预置镜像布局，不能直接当成 loader 应用布局。启动每次复制 .data、清零 .bss。

## 在 scorpion 构建

```sh
python3 software/coremark/build.py --mode smoke
python3 software/coremark/build.py --mode performance --iterations 1
python3 software/coremark/build.py --mode validation --iterations 1
export PATH="$HOME/opt/iverilog-12.0/bin:$PATH"
python3 software/coremark/verify.py
```

每种 build_* 目录含 firmware.elf/map/disasm、firmware.sections.txt、build_manifest.json 和镜像。itcm_full.mem 为 8192 行 32 位小端字，包含地址零跳转；itcm_app.mem 为从 0x1000 开始的 7168 字；dtcm.mem 为 8192 字。B 必须更新实际 RAM 初始化常量并重建位流，仅复制 mem 文件不生效。完整指令和编译链接参数在 manifest；.su 为每函数静态栈信息，不单独等于最坏调用链证明。

## B 接入次序与预期

1. 新计时器硬件先通过 B 自身 RTL/实际 IP/网表/50 MHz STA；保留 C START 回退版。
2. 接 build_smoke：串口输出 TIMER_SMOKE FIRST/SECOND/DELTA/HZ，SECOND>FIRST，HZ=50000000；发送真正完成后 RESULT=1。两次 KEY0 均通过。固定循环不是外部时钟精度证明。
3. 接 build_performance 和 build_validation 的 1 次迭代镜像：用于 CRC 校验，不是正式成绩。正常应打印官方不足 10 秒的 ERROR、完整原始 ticks，最后 RESULT=19。不能因该 RESULT 判断 CPU 算错。

| 模式 | list CRC | matrix CRC | state CRC |
|---|---|---|---|
| performance，种子 0/0/0x66 | e714 | 1fd7 | 8e3a |
| validation，种子 0x3415/0x3415/0x66 | e3c1 | 0747 | 8d84 |

标准总数据量 2000 字节，单上下文、静态内存，算法和种子不为容量修改。CoreMark Size 输出是每算法划分后的尺寸，不应误判为总数据量改变。

## 正式运行

先根据板上真实 ticks 校准迭代数 N_new=ceil(N_old*15*50000000/ticks_old)，再分别重建 performance 和 validation 镜像。实际测量必须至少 500000000 ticks；若不足，增加迭代数重跑。小迭代含固定开销，校准只是估算。

RESULT=1 要求官方验证成功、没有错误且实际至少 10 秒。输出及结束在 stop_time 后，最后等待 TX_IDLE，无逐迭代串口输出。默认整数秒和官方 Total ticks 行在 RV32 上有精度/宽度限制；以额外的 CM_TICKS_HEX 完整记录为准，保留官方输出。

```sh
python3 software/coremark/score.py board-uart.txt
```

该脚本用 Decimal 从完整 ticks 算 seconds、derived CoreMark 与 derived CoreMark/MHz，标明它是原始 ticks 派生数值。正式认可仍需官方正确性、持续时间、赛题口径、实板及时序记录，不能只拿一个派生数字当验收。

正式看门狗建议 180 秒，可根据校准调整；不能沿用 C START 的短超时。保存三次复位运行原始 UART、ELF/镜像/位流哈希、时钟/资源/STA。不要在普通慢 RTL 仿真中强行跑满 10 秒。

## RESULT 编号

1=正式通过（smoke 中表示计时读取通过）；3=UART 等待空闲失败；5=CTRL 禁用读回失败；7=波特率读回失败；9=使能读回失败；11=UART 发送/空闲/错误状态失败；13=不支持输出格式；15=计时频率不匹配；17=数据类型不匹配；19=CoreMark 未满足正式正确性或持续时间；21=smoke 计数没有递增。

## 验证边界

verify.py 使用真实 CPU RTL 加协议 RAM、UART 和新增 timer 测试模型，覆盖两次复位并保留 RAM、官方 CRC、小迭代不得报正式通过、错误频率和不递增计数器负例，以及发送完成后再写 RESULT。test_timer.c 独立测试正常 high-low-high、进位重读、连续重试和 uint64_t 模减法。所有这些均不能替代 B 实际 IP、计时 RTL 和板上验收。

测试台专用边界初态：tb_coremark 把模型计数器初始值设为 0xfffffff0，以便短仿真跨过低字进位并读取非零高字。这是测试注入，不是正式硬件复位语义；实际硬件仍须复位清零。驱动在 high/low 事务之间进位的重试由 test_timer.c 的受控返回序列单独覆盖。
