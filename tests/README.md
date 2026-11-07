# 回归测试

以下命令均从仓库根目录运行。统一入口是 `tools/run_tests.sh`，默认自动发现 `tests/test_*.gd`、`tests/off_work/test_*.gd` 和 `tests/test_*.py` 并运行静态检查。新增用例无需登记到清单。Python 依赖见根目录 `requirements-test.txt`；Godot 与 Node.js 需另行安装。

```bash
python3 -m venv build/test-venv
build/test-venv/bin/pip install -r requirements-test.txt
build/test-venv/bin/python tools/test_runner.py
```

## 分层与功能选择

| 选择 | 内容 |
| --- | --- |
| `--suite gd` | 两款游戏的 GDScript 单元、场景集成与联网回归 |
| `--suite off-work` | 匹配 `tests/off_work/test_*.gd`，包括下班的连续时间规则、真实牌桌、BOT、平衡指标与表现回归 |
| `--suite python` | 构建、资源、工具、测试运行器回归；网页行为由 Python 调用 Node |
| `--suite static` | 卡表、数值、脚本、文档引用检查 |
| `--suite drawer` | 上班抽屉窗口、布局、交互与生命周期 |
| `--suite bot` | 上班 BOT 行为、搜索、取消及计算额度 |
| `--suite network` | 上班协议、网络同步、房间、重连与托管 |

gd、python、static 按执行层划分，其余按玩法或功能筛选。功能选择集不取代完整回归；例如抽屉调用 BOT 的交叉场景也可能位于 BOT 用例中。重复 `--suite` 取并集、去重，位置参数再按名称取交集。`--list` 可检查实际选择，不启动 Godot、不生成日志。

```bash
tools/run_tests.sh --suite drawer --list
tools/run_tests.sh --suite drawer --suite bot
tools/run_tests.sh --suite gd status_layout
TEST_SPEED=1 tools/run_tests.sh --suite drawer
```

要单独核查两种玩法的交接或下班的专项能力，可用下列名称过滤。指定 `--list` 可先确认匹配文件。

```bash
tools/run_tests.sh shift_persistence          # 上下班切换、独立存盘与恢复
tools/run_tests.sh work_lan                   # 下班局域网牌局
tools/run_tests.sh --suite off-work bot       # 下班 BOT、搜索与截止时间
tools/run_tests.sh --suite off-work work_lesson       # 下班课程、慢读/乱序操作、购牌手势与存档隔离
tools/run_tests.sh --suite off-work work_tool_lesson  # 深摞抽牌、开会、甩锅的实际拖拽与误拆恢复
tools/run_tests.sh work_learning_center              # 共用课程/图鉴导航、卷度关系与当前卡表参数
tools/run_tests.sh --suite off-work work_lab_metrics
tools/run_tests.sh off_work_virtual_clock    # 下班无头实验按游戏秒快进
tools/run_tests.sh shift_workbench           # 共享工作台、历史恢复、脚本提交与原生试玩
```

下班课程回归按 `first → extract → overtime → upgrade → meeting → transfer → interrupt → solo` 的顺序覆盖八课。前七课在读提示和操作时等待玩家，只在观察产出、提升卷度、开会及冷却恢复等结果时推进时钟。第八课用双方各 48 张工作、正式 BOT 和正常连续时间完成独立对局。

三节新增课程保留实际输入与规则结果的检查。

- 「从深摞抽出同类牌」从 200 张工作、3 名员工和 1 张加班的混合深摞开始。点击右侧员工图标旁的「×3」只展开员工扇牌，从第一张拖出 3 名员工后，原堆仍有全部工作和加班。
- 「开会，留人生产」把开会牌交给独立领导主持，检查对手被召集后暂停，己方另一个生产组仍能结算收入。
- 「甩锅与恢复收入」先检查人员、工作和甩锅同组时转移工作且收入不增加，再通过类型扇牌抽出甩锅，检查原组恢复处理工作并产生收入。

课程用例同时覆盖慢读提示、提前操作、拆错组合后的恢复、演示与亲手完成的学习记录、重练与退出，以及正式牌局的存档隔离。`test_work_lesson_restore_visual.gd` 检查所有课程进出的首帧牌面与实际阴影缓存、连续切课、分类扇牌关闭，以及暂停牌局恢复时的即时布局，防止切换时出现空卡形残影。

## 公共夹具与覆盖边界

- `harness.gd`：断言计数、独立用户数据、真实主场景、动画同步、联网驱动、收尾。
- `support/drawer_fixture.gd`：抽屉启动、布局同步、释放与显示尺寸矩阵；`manual_window` 显式控制是否由测试驱动窗口。
- `fixtures/`：冻结输入数据和参考结果；支持代码不能以 `test_` 命名，避免当作独立测试执行。

同一个行为的尺寸、DPI、胜负、座位差异用数据表驱动；不同业务契约仍各自保留独立断言。共享准备过程，不把被测实现输出当作预期值。涉及真实输入、窗口或网络生命周期时保留集成用例，不以源码字符串检查替换。

## 执行与诊断

Godot 测试启动前，入口串行执行资源导入，补齐首次运行或丢失的导入缓存，并与构建共用 `build/.font-transaction.lock`。准备失败会停止用例启动，报告为“未运行”；`prepare_resources.log` 记录原因。纯静态检查不依赖 Godot。Godot 可用时 Python 选择集也准备缓存，供其子进程使用。

每个测试在独立进程与用户数据目录中运行，默认超时 180 秒，可用 `--jobs`、`--timeout` 或 `JOBS`、`TEST_TIMEOUT` 调整。超时与取消会清理测试进程及后代。日志和 `results.json` 保存在 `build/test-results/` 下，分别统计断言、Python 用例、跳过及静态检查。

`TEST_SPEED=5` 是默认的游戏时间加速；物理步长保持一致。涉及真实时间、输入或布局同步的变更，应补跑 `TEST_SPEED=1`。可选素材缺失时允许带原因的 `SkipTest`，包括整类跳过；没有任何用例、跳过或汇总的空测试文件始终失败。

## 上班对手行动与结算帧性能

`tools/on_work_profile_turn_frames.gd` 用固定发牌种子、同一产出组合和真实 BOT 行动路径采样，强制正常游戏时间及每秒 60 个物理步。默认不会移动系统光标；需要观察系统手形光标时，可手动把鼠标放在牌桌上，或显式加 `--move-pointer` 自动扫过牌桌。运行时不要同时启动其它性能探针或回归进程。

下面两条真实 GPU 命令分别在修改前、修改后的代码版本运行（不要添加 `--headless`）：

```bash
"$GODOT" --path . --script tools/on_work_profile_turn_frames.gd -- --seed=42 --output=build/turn-frames-before.json
"$GODOT" --path . --script tools/on_work_profile_turn_frames.gd -- --seed=42 --output=build/turn-frames-after.json
```

报告记录启动、构造组合、静止、BOT 思考/行动、攻击、结算和回合完成后的帧间隔，以及 `frame_pre_draw` 到 `frame_post_draw` 的墙钟跨度；分别统计 p50、p95、最大值和超过 30ms 的样本，并保留原始数值、阶段、实体数、显卡、窗口/缩放、光标模式与原生光标键。渲染信号跨度包含驱动同步，不等于 GPU 纯执行耗时。比较前后报告时确认 seed、局面哈希、窗口、缩放、显卡一致；启动阶段包含首次材质/纹理等开销，应与暖机后的行动/结算分开看。

采样时保持窗口在前台。长帧上下文含 `focused`；伴随失焦或切窗的停顿应在独占、持续聚焦条件下复验。

默认 60 秒超时，可用 `--timeout=90` 调整（上限 300 秒）。完成、超时或关闭窗口均写入 `build/` 内 JSON，记录状态和场景释放结果；成功退出码为 0，失败为非零。独立用户数据由公共 harness 清理。超时通过主循环看门狗检测，无法抢占引擎或驱动永久阻塞；自动化调用仍应加进程外超时兜底。

`--headless --check-only --script tools/on_work_profile_turn_frames.gd` 仅用于解析检查。无头运行没有真实 GPU 呈现，其报告会明确标记渲染测量无效，不能据此断言鼠标跟随或实际渲染卡顿已改善。

## 下班牌桌帧性能

下班用固定的工作堆与人员配置分别采样空闲、结算、拖拽阶段。固定步进模式用于比较规则推进和牌桌脚本的 CPU 耗时；真窗口模式包含实际帧间隔。对照前后表现时使用相同模式、场景和采样帧数。

```bash
"$GODOT" --headless --path . --script tests/off_work/benchmark_work_runtime.gd -- --frames=90 --output=build/work-runtime-cpu.json
"$GODOT" --path . --script tests/off_work/benchmark_work_runtime.gd -- --real-window --frames=90 --output=build/work-runtime-window.json
```
