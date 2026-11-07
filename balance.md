# 牛马牌 · 手动调参说明

上班和下班共用调参工作台。每次实验都记录提交时的卡表和 BOT 参数，可用历史指标和真人试玩结果判断下一次改动。两个玩法分别读取 `data/on_work_cards.json` 和 `data/off_work_cards.json`；要更换游戏默认值，需主动导出并替换相应文件。

## 打开工作台

双击项目根目录的 `启动手动调参.command`。它会在本机启动服务并打开浏览器。关闭最后一个工作台标签页后，服务会等两种玩法的实验结束再退出。终端按 Ctrl+C 即刻停止服务和模拟，也可运行 `./启动手动调参.command --stop` 停止空闲工作台。再次双击会复用同版本的实例，或接替旧版本的空闲实例。上班和下班的实验数据分别保存在 `reports/manual_balance/` 和 `reports/balance_lab/`。

## 下班 · 连续时间调参

在顶部选择「下班」。在平衡性调参页选择项目默认卡表、已保存版本或历史实验的配置，先调全局规则，再按卡修改参数。卡表评估让双方使用同一套 BOT。想亲自试手感，可从卡表编辑区用当前参数启动原生下班游戏。

要比较两套 BOT，切到「BOT 对战比较」：顶部选择一份双方共用的卡表，A、B 分别选择相同或不同的强度，也可载入策略或调整全部参数。点击「保存卡表及 A、B 策略并对战」会保存共用卡表、A 策略和 B 策略，然后创建一条对战记录。相同参数自动复用已有配置和名称；同名但参数改变时会先确认覆盖。只需保存一方时，使用该方的「仅保存 BOT A 策略」或「仅保存 BOT B 策略」。材料候选上限、保底探测组数、预测窗口和估值权重均可逐项修改，具体口径见 [BOT 参数说明](bot.md#下班-bot-的搜索与决策时限)。

每次提交只运行当前卡表，每个种子交换双方座位各打一局。BOT 历史表每行是一条 A 对 B 的实验，保留所有卡表下的记录，最新记录在前。展开详情可直接查看本次双方的胜局、分胜负胜率和策略参数差异。平衡评估与 BOT 对战记录都用进度条显示已完成／计划局数，运行中持续更新，停止后保留实际完成量。两份卡表或两次平衡实验的比较放在平衡性调参页。

每局的时限填写**游戏内秒数**。无头模拟直接推进到下一次 BOT 决策，在此期间由游戏规则结算生产、购牌区补给、开会和其他定时效果。例如 600 秒表示在牌局时间 10 分钟时仍未结束就记为超时。评估记录中的「累计游戏时长」加总各局推进的虚拟秒数，「计算耗时」记录执行这些模拟所花的实际时间。

下班 BOT 默认拿行动间隔的 50% 作为决策时限。双方间隔为 2.8 游戏秒时，每次最多思考 1,400 毫秒；修改间隔后页面会重新计算。早期策略可继续使用固定毫秒数。实验详情会列出实际分支节点、完整搜索步数和主变化，可以顺着双方的动作核对一次购买、派工或开除。实战与无头模拟共用搜索器。调参只花实际计算所需时间，不会等待行动间隔或用满思考时限。

「搜索范围」可以设置 `search_max_depth`（最大搜索深度，默认 4）、`search_root_width`（首步候选宽度，默认 3）和 `search_reply_width`（后续分支宽度，默认 2），均为 1–16 的整数。一层是单方一次行动，默认 4 层对应我方／对手／我方／对手。首步候选中没有等待时，会额外保留等待分支。提高深度或宽度仍受决策时限约束，超时采用最近完整搜索层的结果；历史策略缺少的新字段按原算法默认值补齐显示。

| 维度 | 指标及分母 |
| --- | --- |
| 先手胜率 | 先手获胜局数 ÷ 有先手且自然结束的局数。最先获得行动机会的一方为先手，选择等待也算；双方同刻依实际调度顺序判定。平局计入分母，超时局与无人获得行动机会的局跳过 |
| 对局节奏 | 已结束局的平均游戏时长（含平局），以及达到时限的局数占全部对局的比例 |
| 卡牌选择 | 购牌覆盖率统计至少买过一次的可购卡种数，占卡表全部可购卡种的比例。获得卡牌分布另按张数统计，分母是双方在本批对局中购买、升级获得或生产的非资源牌总张数。开局配牌、工作和金钱排除，未获得的卡种列为零张 |
| 提升卷度 | 双方每局喝咖啡后实际完成的卷度提升次数，折算为次／游戏分钟，再取各局平均 |
| 道具生成 | 双方每局成功生产道具的次数，折算为次／游戏分钟，再取各局平均。一次摸鱼产出 3 杯咖啡，生成记 1 次，获得卡牌分布记 3 张咖啡 |
| 玩家干扰 | 双方每局实际生效的甩锅、开会、罢工次数，折算为次／游戏分钟，再取各局平均。一次甩出多份工作或一次影响多名人员，都以一次结算计数 |

三个频率均先用单局事件次数乘 60，再除以本局实际推进的游戏秒数。每个正时长对局权重相同，平局和超时局也参与；某局零次时该局频率为 0。例如两局分别在 30 秒内升级 1 次、120 秒内升级 2 次，本批平均为 (2 + 1) ÷ 2 = 1.5 次／游戏分钟。历史实验只显示原始记录足以还原的观测值。

记录按最近提交时间排列。在平衡性调参页选择两个历史实验可对比指标和实际参数，也可选项目默认卡表作参照。对比时会标出种子、时限、BOT 或模拟器版本的差异。若默认卡表尚无已完成的实验，可先看参数差异，需要实测参照时再单独提交。试玩备注随卡表版本保存。保存同名新参数需要确认覆盖，历史实验继续引用提交时的快照。

网页和脚本使用同一个运行接口。以下命令运行 3 对种子，共 6 局，结果 JSON 中的 `experiment_url` 可直接在工作台打开本次记录。将 `--kind balance` 改为 `--kind bot` 可运行 BOT 对战，`--no-wait` 可在提交成功后立即取得链接。

```bash
python3 tools/balance/off_work_cli.py --kind balance --cards data/off_work_cards.json --name 默认卡表 --pairs 3 --seed 1001 --max-seconds 600
```

手头已有下班卡表文件时，也可以直接用构建好的 macOS 游戏试玩。将参数换成自己的卡表路径即可。

```bash
./启动游戏.command --off-work-playtest "--cards-config=$PWD/data/off_work_cards.json"
```

## 上班 · 回合制调参

1. 从默认配置、已有手动版本或旧实验的完整候选卡表开始。导入卡表若包含可选 `_name` 字段，则用它作为起点名称；否则使用文件名。
2. 在中文表格中调整合法参数并填写“新版本名称”。名称和卡牌参数均未变化时复用已有配置；创建新配置需要未使用的新名称和修改后的卡牌参数。仅改名称、仅改参数或名称重复时，相关按钮置灰并提示原因。保存、评估与试玩沿用同一套配置校验。
3. 只需保留修改时，点击“保存并运行当前配置”左侧的“仅保存配置”。它会保存当前配置及试玩备注，不启动模拟或游戏，也不新增评估记录。生成的 `configs/<配置ID>.json` 是完整卡表，可直接用来替换 `data/on_work_cards.json`。
4. 需要评估时，设置种子对数、每局回合上限、起始种子和双方整体 BOT 强度（0～1，默认 0.5）；高级区展示并允许修改全部真实 BOT 参数。
5. 点击“保存并运行当前配置”。后台调用真实 Godot `OnWorkMatchSimulator`；创建评估记录时立即开始计时，进度、当前回合、实时耗时和阶段性指标都显示在对应的评估记录行内。已有任务运行时，可以继续提交同一配置或其他配置的模拟，各任务并行运行。
6. 在“编辑卡牌配置”中点击“保存并以当前配置启动游戏”，先保存当前配置及备注，再用这份卡组打开单机游戏试玩。未保存的新版本会先创建配置，已有版本直接复用；试玩不创建评估记录，也不受模拟局数或 BOT 参数表单的影响。
7. 在配置名称附近记录试玩备注。备注跟随配置切换，可以独立保存；新配置可用“保存配置与备注”或“仅保存配置”保存，无需启动评估。
8. 在比较区选择两份配置和各自一次已完成模拟，查看指标差、卡牌参数差与试玩备注。

每条正在运行的评估记录都有自己的“停止模拟”按钮。点击后，该条显示“正在停止”并禁用重复点击；其他任务继续运行，也可继续提交新任务。停止后保留配置、已完成局的进度与历史结果。任务完成、取消或出错后，不再提供可执行的停止按钮。排序和进度刷新不会收起已展开的获得卡牌或获胜分布。

各任务使用独立 Godot 进程及 `runs/<任务ID>/` 目录，卡表、模拟参数、日志、进度和结果互不覆盖。停止按钮按任务 ID 定位进程；关闭服务时回收所有仍在运行的模拟，独立打开的试玩游戏不受影响。

模拟种子对数和每局回合上限不设置固定预算上限，起始种子也不限定为 32 位或预留固定种子数。三项均须为正整数，并在浏览器与 JSON 能精确表示的整数范围内（不超过 `2^53−1`）；总局数 `种子对数×2` 和最后一个种子 `起始种子＋种子对数−1` 也必须在该范围内。这是数值正确性约束，不是运行时长限制。每局回合上限仍由用户填写，达到该值按未结束局统计；任务可随时停止。

Q1–Q11 及获得卡牌、获胜方式分布采用增量累计：每局模拟完成只添加一次计数，再生成指标快照。局内进度刷新复用最近快照，最终报告也使用同一份快照，不反复重扫已完成对局。统计快照的计算量取决于卡种及获胜类别数，不随历史局数增加。完整逐局记录仍保留在最终报告中，因此总结果的内存、文件大小和最终序列化耗时会随局数增长。

页面耗时是各任务的实际墙钟时间，包含并行任务对计算资源的竞争；衡量单项模拟速度时应与相同并发条件比较。

网页试玩使用工作台所配置的 Godot 启动当前项目，传入 `--cards-config=<配置快照的绝对路径>`。快照保存在 `reports/manual_balance/playtests/`，游戏确认加载这份卡表后，网页才显示启动成功；启动失败会显示原因及日志位置。试玩启动时使用游戏默认 BOT 设置（强度 0.5），可在游戏中即时调整，本次运行结束后不保留；模拟区的参数只控制评估。

点击「导出上班卡表…」可把当前编辑的完整卡表保存到选定位置，默认文件名为 `on_work_cards.json`。需要替换游戏默认值时，选择项目的 `data/on_work_cards.json`。

工作台将版本信息保存在 `config_meta/<配置ID>.json`，备注仍在 `notes/`，评估仍在 `runs/`；它们通过原配置 ID 关联。启动时会将旧封装配置转换为“纯卡表＋独立版本信息”，保留原 ID、名称、参数、备注与历史评估。`config_meta`、备注及评估记录不是游戏卡表，不能用于覆盖 `data/on_work_cards.json`。

导出的桌面 App 也支持同一参数，例如 `./启动游戏.command --rebuild "--cards-config=/path/to/cards.json"`。启动时指定的卡表优先于游戏选项中保存的选择，只作用于此次进程，单机重开继续使用它；未指定参数时保持原来的选择行为。联网仍使用内置默认卡表。文件不存在或不合法时明确报错，不会静默换成默认卡表试玩。

如果本地留有旧版实验目录，可导入其中 `reports/balance_search/candidates/*.json` 的完整卡表。重新评估后即可得到当前版本的 Q 指标。

## 上班 · BOT 对战比较

页面最下方的“BOT 对战比较”使用当前编辑的同一份卡表，A、B 分别拥有 0～1 整体强度滑钮和全部可调参数。0.5 对应原基线，1 对应最高强度参数组合，默认 A 为 0.5、B 为 0。两方参数都按设计能力、计算预算和评估等类别分组，逐项显示数值范围、步长与含义。

页面加载时，后端通过与游戏相同的解析器生成 0～1、步长 0.01 的全部参数快照。拖动任一方的滑钮时，页面立即用对应快照更新该方整套参数，无需松手，也不会为每一步重复启动计算；另一方保持原值。随后可逐项手动修改；再次拖动会清除该方手动覆盖。映射加载期间不能启动对战，连续拖动只采用最新强度的结果。点击“保存并开始 BOT 对战”后先保存卡表与备注，再启动独立任务；双方完整参数在提交时校验并冻结，后端不重新套用分档，也不受后续表单修改影响。

每个种子交换 A、B 座位各模拟一次，保持同一套合法动作、胜负判定和行动顺序。模块单独显示双方胜局、未结束局、分胜负胜率、未结束率、得分率、平均模拟回合和 A 在开局先后手的胜负。分胜负胜率以已分胜负局为分母；得分率以已模拟局为分母，未结束局各计半分。平均回合包含未结束局实际观察到的回合。零分母显示“未观测”。

实时统计仅增量添加刚完成的一局，不反复扫描历史。最终完成时才计算一次 A 得分率的种子对 bootstrap 区间；少于两对不计算区间。未完成的半对可以进入阶段计数，但阶段结果不提供成对置信区间。区间不能消除少量样本、卡表或种子选择的影响；预算不同的配置对战也不证明等算力优劣。

对战任务与卡表评估共用进程管理，各自停止互不影响。停止或服务中断后保留已落盘阶段统计；完整逐局记录和最终区间在正常完成时提供。“导出记录与实际参数”包含任务条件、双方解析参数、卡表快照、进度及已生成的结果，完成报告还包含源码和卡表指纹。BOT 对战记录不会混入 Q 指标列表或卡表差异比较。

两班 BOT 的搜索、时间预算和实验入口见 [BOT 设计](bot.md)。

## 上班卡表的可调范围

`C` 指 `data/on_work_cards.json`。界面只允许改：

- 市场卡的 `price` 与正 `weight`；
- 所有非资源卡的出售价格 `pawn`；
- 已存在的 `recipe_n`、`output_n`、`attack_n`；
- `C._game.start_cash`、`C._game.start_user`。

数值边界由 `data/on_work_card_config_schema.json` 统一声明，游戏、评估与网页编辑器共用：初始现金 1–99 且低于胜利线；初始用户、配方需求、产出量和攻击量 1–200；购买价格 1–1000；市场权重 1–1000000；出售价格 0–1000，0 表示不可出售。资源按单位卡逐张创建，因此拒绝超出这些运行规模边界的配置。原本没有 `pawn` 的卡牌显示“自动”，留空时不写入覆盖值，继续由游戏的 `OnWorkCardDB.pawn_value()` 按购买价格和升级来源计算；原本有固定 `pawn` 的传说卡直接编辑该数值，不能留空。网页和后端不另行实现出售价格公式。

除可选 `pawn` 覆盖外，卡牌集合、字段集合、资源类型、卡牌类别、升级路线、Buff 语义、市场大小、胜利条件等保持不变。保存和导出的上班配置都是完整卡表。游戏中可在「选项 → 卡牌配置」导入，工作台的「导出上班卡表…」可选择保存位置，默认文件名为 `on_work_cards.json`。手动评估和游戏导入共享 `engine/on_work_card_config_rules.gd` 的完整卡表校验，实际读取都由 `OnWorkCardDB.load_from()` 完成。

当前传说规则：恰好 4/6/8 张任意 T1 生产卡，或恰好 2/3/4 张任意 T2 生产卡，分别合成独角兽／国民应用／上市敲钟。同档可以异名，不能混档或夹带其他牌；两张同名 T1 升对应 T2 的路线保留。所有配置使用同一份引擎规则，历史评估不会自动更新，需要重新运行。旧卡表说明文字差异不影响导入，实际规则字段仍需一致。

## Q1–Q11：直接观测值

每个种子交换开局先手各跑一局。所有比例直接显示百分比和“分子 / 分母”；分母为零时显示“未观测”，不会把未知当成 0，也没有“证据不足”状态。

| 指标 | 含义 | 公式与读法 |
|---|---|---|
| Q1 先手胜率 | 开局先手赢了多少 | 先手获胜局数 / 已结束局数。接近 50% 表示本批次较对称，不是越高越好。 |
| Q2 平均结束回合 | 已结束局通常多长 | 已结束回合总和 / 已结束局数。未结束局不混入平均，须与 Q3 一起看。 |
| Q3 未结束比例 | 达到上限仍未结束多少 | 未结束局数 / 已模拟局数。0% 表示本批次全部结束，是正常结果。 |
| Q4 有效反馈比例 | 有实际结果的行动回合有多少 | 有正产出、成功升级、成功攻击或典当直接获胜的座位回合 / 实际发生的座位行动回合。同一座位同一回合只计一次。它是事件密度，不是“爽感分”。 |
| Q5 双方攻击比例 | 有多少局形成双向攻击 | 双方都曾成功攻击的对局数 / 已模拟局数。只有单方攻击不算。 |
| Q6 卡牌使用覆盖 | 这批对局触达了多少卡种 | 买入、有效编组使用或升级产物中出现的不同非资源卡种 / 全部非资源卡种。买入即计覆盖，不代表这张牌有用；局数增加通常会提高此值。 |
| Q7 升级后成功生产 | 有多少局兑现过升级产物的生产收益 | 至少一方用本局升级生成的卡牌成功生产过正产出的对局数 / 已模拟局数。同局只计一次，不要求该方获胜；仅合成、典当升级产物、生产被打断或零产出均不计。 |
| Q8 局均最大现金数 | 每局曾达到的最高现金数平均是多少 | 每局任意一方持有的最大现金数之和 / 有现金峰值记录的局数。包含开局和未结束局已观测到的峰值。 |
| Q9 局均最大用户数 | 每局曾达到的最高用户数平均是多少 | 每局任意一方持有的最大用户数之和 / 有用户峰值记录的局数。包含开局和未结束局已观测到的峰值。 |
| Q10 获胜方式多样性 | 已归类胜局相当于均匀使用多少种获胜方式 | `exp(−Σ pᵢ ln pᵢ)`，其中 `pᵢ` 是每种方式占已归类胜局的比例，零次类别不参加求和。单位为“种”；1 表示单一方式，上限为该配置支持的分类数。没有已归类胜局时显示“未观测”。 |
| Q11 典当后获胜比例 | 有多少局由曾典当的一方赢得 | 最终获胜方曾成功典当过的对局数 / 已模拟局数。普通卡、用户和传说均计；不要求典当直接致胜。双方都典当且有胜者也只计一局；只有败者典当、或尚未结束均不计分子。 |

Q6 可展开“获得卡牌分布”，比较区同时列出 A / B 明细，差异导出保留完整统计。双方每获得一张非资源卡计一次，包括购买、升级生成和其他实际发牌来源；同名牌重复获得累计。不计现金牌、用户牌、失败动作和 BOT 搜索中的假想发牌；同一张牌后续使用或出售不再计数，升级消耗材料也不回减其历史获得次数。占比为该卡获得张数 / 所有非资源卡获得总张数，包含已模拟但未结束的局。未获得的卡种保留零值；没有获得非资源卡时占比显示“未观测”。分布与卡种覆盖率独立。旧记录没有获得事件，显示“未观测”，不能从 used_cards 或仅有的购买记录反推升级获得次数；混合汇总单列已观测和未采集局数。

Q7 跟踪成功升级生成的实际卡牌实例及所属方，后续由该实例完成有正产出的生产才命中；购买或其他来源取得的同名卡不会混算。Q7 是对局比例，不是“升级产物中有多少比例回本”，也不衡量收益是否已覆盖升级成本。

Q11 是“典当后获胜的对局占全部已模拟对局的比例”，不是“发生典当的玩家的条件胜率”。例如四局中：赢家典当过、只有败者典当过、双方典当且有赢家、双方典当但未结束，Q11 为 2/4 = 50%。同一方多次典当、同局双方典当均不重复计数；失败或空典当不计。

当前指标版本为 `manual-eleven-v4`。旧 Q7“升级发生比例”不能推算新 Q7，旧记录也未采集 Q11 所需的典当方信息，页面均显示“未观测”，须重新评估；原始历史记录不改写。新 Q7 带有独立定义标记，列表、阶段进度、排序、比较图及差值导出都不会混用旧值。批次阶段指标只汇总已完成模拟的局；到达上限仍未结束的局也属于已模拟局，Q7 可命中、Q11 不命中。若离线汇总混有未采集新字段的旧局，对应指标仅使用有有效观测的局作分母，不将缺失值补为零。

Q8、Q9 先分别求每局峰值，再求各局的算术平均：例如三局的现金峰值为 40、60、50，Q8 为 50。每局取双方各自持有数量中的最高值，不把双方资源相加；现金峰值和用户峰值可以来自不同玩家、不同时间。统计覆盖开局、真实行动和逐组结算，避免只看回合结束时漏掉中途产出后又花掉的现金；BOT 搜索副本中的假想资源不计入。

历史评估没有记录峰值，Q8、Q9 显示“未观测”，重新模拟后才有数据。图表分别使用百分比、回合、现金和用户的单位，资源数量不会被截断到 100。

Q10 衡量**导致胜利的最终机制**的分布：常规分为普通现金达标、对手现金清零、对手用户清零；配置中的每种可出售传说卡各有一类“该传说变现达标”。若导致胜利的同一次典当包含多种传说，归入“多种传说共同变现达标”，不会任意挑一张作为原因；配置至少有两种可出售传说时才支持这一类。早先卖过传说、后来靠其他事件获胜，不算传说变现致胜。

例如两种方式各占一半时，Q10 为 2；若占比分别为 90% 和 10%，有效方式数约为 1.38。当前配置有三种传说，因此支持三个常规类别、三个独立传说类别和一个混合传说类别，共七类；上限跟随本次配置，由报告提供，页面不硬编码。零次类别仍显示在分布中，但不会抬高观测值。这个数反映终局机制多样性，不等于打法或乐趣多样性，也不是越高越好。

只有已结束且能归类的胜局进入 Q10 及其分布占比；未结束局不计，已结束但缺少有效终局信息的局数单列为“未归类胜局”。页面同时显示各方式的局数、占比、已归类样本数和配置上限，避免把小样本的单一结果误读为稳定结论。评估行可展开获胜分布，比较区同时列出 A / B 的分布，差异导出保留完整明细。历史记录缺少 Q10 时显示“未观测”，不从旧结果猜测类别；Q10 使用独立“种”轴，轴上限取 A / B 配置分类数的较大值。

## 对比边界

`B − A` 始终是直接算术差。只有两次结果的种子、局数、回合上限、双方实际 BOT 参数、新指标版本和引擎指纹都一致，页面才标记为测量条件一致。即便一致，它仍不自动证明统计显著或体验更好；需要结合试玩备注判断。

少量对局适合验证改动方向，不适合下稳定结论。若关注稀有卡或升级，增加种子对数；若 Q3 较高，再增加回合上限以区分“真的僵局”和“观察窗口太短”。

## 卡牌总表

此表列出上班牌的配置字段。下班使用独立卡表，字段与指标见本文的「下班 · 连续时间调参」。

以下仅索引配置字段，非新增数值定义；由 `tools/on_work_check_card_table.py` 检查引用与覆盖。

### 基础单位卡

| 卡牌 | 定义 | 资源 | 开局数量 | 典当 |
|---|---|---|---|---|
| 现金 | `C.cash` | `C.cash.res` | `C._game.start_cash` | `pawn(C.cash)` |
| 用户 | `C.user` | `C.user.res` | `C._game.start_user` | `pawn(C.user)` |

### T1 创业产品

| 卡牌 | 定义 | 配方 | 产出 | 价格 / 权重 | 典当 |
|---|---|---|---|---|---|
| 云课堂 | `C.yunketang` | `C.yunketang.recipe_res` × `C.yunketang.recipe_n` | `C.yunketang.output_res` × `C.yunketang.output_n` | `C.yunketang.price` / `C.yunketang.weight` | `pawn(C.yunketang)` |
| 连续包月 | `C.baoyue` | `C.baoyue.recipe_res` × `C.baoyue.recipe_n` | `C.baoyue.output_res` × `C.baoyue.output_n` | `C.baoyue.price` / `C.baoyue.weight` | `pawn(C.baoyue)` |
| 拼少少 | `C.pinshaoshao` | `C.pinshaoshao.recipe_res` × `C.pinshaoshao.recipe_n` | `C.pinshaoshao.output_res` × `C.pinshaoshao.output_n` | `C.pinshaoshao.price` / `C.pinshaoshao.weight` | `pawn(C.pinshaoshao)` |
| 刷不停 | `C.shuabuting` | `C.shuabuting.recipe_res` × `C.shuabuting.recipe_n` | `C.shuabuting.output_res` × `C.shuabuting.output_n` | `C.shuabuting.price` / `C.shuabuting.weight` | `pawn(C.shuabuting)` |
| 地推扫码 | `C.ditui` | `C.ditui.recipe_res` × `C.ditui.recipe_n` | `C.ditui.output_res` × `C.ditui.output_n` | `C.ditui.price` / `C.ditui.weight` | `pawn(C.ditui)` |
| 外卖补贴 | `C.waimai` | `C.waimai.recipe_res` × `C.waimai.recipe_n` | `C.waimai.output_res` × `C.waimai.output_n` | `C.waimai.price` / `C.waimai.weight` | `pawn(C.waimai)` |
| 广告投流 | `C.touliu` | `C.touliu.recipe_res` × `C.touliu.recipe_n` | `C.touliu.output_res` × `C.touliu.output_n` | `C.touliu.price` / `C.touliu.weight` | `pawn(C.touliu)` |
| 春晚冠名 | `C.chunwan` | `C.chunwan.recipe_res` × `C.chunwan.recipe_n` | `C.chunwan.output_res` × `C.chunwan.output_n` | `C.chunwan.price` / `C.chunwan.weight` | `pawn(C.chunwan)` |

### T2 行业巨头

| 卡牌 | 定义 | 升级来源 / 数量 | 配方 | 产出 | 价格 / 权重 | 典当 |
|---|---|---|---|---|---|---|
| 信息茧房 | `C.xinxijianfang` | `C.xinxijianfang.upgrade_from` / `C.xinxijianfang.upgrade_dup_n` | `C.xinxijianfang.recipe_res` × `C.xinxijianfang.recipe_n` | `C.xinxijianfang.output_res` × `C.xinxijianfang.output_n` | `C.xinxijianfang.price` / `C.xinxijianfang.weight` | `pawn(C.xinxijianfang)` |
| 百亿补贴 | `C.baiyibutie` | `C.baiyibutie.upgrade_from` / `C.baiyibutie.upgrade_dup_n` | `C.baiyibutie.recipe_res` × `C.baiyibutie.recipe_n` | `C.baiyibutie.output_res` × `C.baiyibutie.output_n` | `C.baiyibutie.price` / `C.baiyibutie.weight` | `pawn(C.baiyibutie)` |
| 半价生活圈 | `C.banxiaoshi` | `C.banxiaoshi.upgrade_from` / `C.banxiaoshi.upgrade_dup_n` | `C.banxiaoshi.recipe_res` × `C.banxiaoshi.recipe_n` | `C.banxiaoshi.output_res` × `C.banxiaoshi.output_n` | `C.banxiaoshi.price` / `C.banxiaoshi.weight` | `pawn(C.banxiaoshi)` |
| 地推冲锋队 | `C.tuanzhang` | `C.tuanzhang.upgrade_from` / `C.tuanzhang.upgrade_dup_n` | `C.tuanzhang.recipe_res` × `C.tuanzhang.recipe_n` | `C.tuanzhang.output_res` × `C.tuanzhang.output_n` | `C.tuanzhang.price` / `C.tuanzhang.weight` | `pawn(C.tuanzhang)` |
| 流量黑洞 | `C.liulianghe` | `C.liulianghe.upgrade_from` / `C.liulianghe.upgrade_dup_n` | `C.liulianghe.recipe_res` × `C.liulianghe.recipe_n` | `C.liulianghe.output_res` × `C.liulianghe.output_n` | `C.liulianghe.price` / `C.liulianghe.weight` | `pawn(C.liulianghe)` |
| 焦虑贩卖机 | `C.jiaolv` | `C.jiaolv.upgrade_from` / `C.jiaolv.upgrade_dup_n` | `C.jiaolv.recipe_res` × `C.jiaolv.recipe_n` | `C.jiaolv.output_res` × `C.jiaolv.output_n` | `C.jiaolv.price` / `C.jiaolv.weight` | `pawn(C.jiaolv)` |
| 自动续费矩阵 | `C.xufei` | `C.xufei.upgrade_from` / `C.xufei.upgrade_dup_n` | `C.xufei.recipe_res` × `C.xufei.recipe_n` | `C.xufei.output_res` × `C.xufei.output_n` | `C.xufei.price` / `C.xufei.weight` | `pawn(C.xufei)` |

### T3 传说

| 卡牌 | 定义 | 升级来源 / 数量 | 回收价 | 价格 / 权重 |
|---|---|---|---|---|
| 独角兽 | `C.dujiaoshou` | `C.dujiaoshou.upgrade_from` / `C.dujiaoshou.upgrade_dup_n` | `C.dujiaoshou.pawn` | `C.dujiaoshou.price` / `C.dujiaoshou.weight` |
| 国民应用 | `C.guomin` | `C.guomin.upgrade_from` / `C.guomin.upgrade_dup_n` | `C.guomin.pawn` | `C.guomin.price` / `C.guomin.weight` |
| 上市敲钟 | `C.shangshi` | `C.shangshi.upgrade_from` / `C.shangshi.upgrade_dup_n` | `C.shangshi.pawn` | `C.shangshi.price` / `C.shangshi.weight` |

### 攻击卡

| 卡牌 | 定义 | 配方 | 攻击 | 价格 / 权重 | 典当 |
|---|---|---|---|---|---|
| 补贴大战 | `C.butie` | `C.butie.recipe_res` × `C.butie.recipe_n` | `C.butie.attack_res` × `C.butie.attack_n` | `C.butie.price` / `C.butie.weight` | `pawn(C.butie)` |
| 黑公关通稿 | `C.heigongguan` | `C.heigongguan.recipe_res` × `C.heigongguan.recipe_n` | `C.heigongguan.attack_res` × `C.heigongguan.attack_n` | `C.heigongguan.price` / `C.heigongguan.weight` | `pawn(C.heigongguan)` |
| 做空报告 | `C.zuokong` | `C.zuokong.recipe_res` × `C.zuokong.recipe_n` | `C.zuokong.attack_res` × `C.zuokong.attack_n` | `C.zuokong.price` / `C.zuokong.weight` | `pawn(C.zuokong)` |
| 二选一 | `C.eryouxuan` | `C.eryouxuan.recipe_res` × `C.eryouxuan.recipe_n` | `C.eryouxuan.attack_res` × `C.eryouxuan.attack_n` | `C.eryouxuan.price` / `C.eryouxuan.weight` | `pawn(C.eryouxuan)` |
| 差评轰炸 | `C.chaping` | `C.chaping.recipe_res` × `C.chaping.recipe_n` | `C.chaping.attack_res` × `C.chaping.attack_n` | `C.chaping.price` / `C.chaping.weight` | `pawn(C.chaping)` |
| 山寨围剿 | `C.shanzhai` | `C.shanzhai.recipe_res` × `C.shanzhai.recipe_n` | `C.shanzhai.attack_res` × `C.shanzhai.attack_n` | `C.shanzhai.price` / `C.shanzhai.weight` | `pawn(C.shanzhai)` |

### Buff 卡

| 卡牌 | 定义 | 效果类型 | 效果量 | 价格 / 权重 | 典当 |
|---|---|---|---|---|---|
| 裂变鬼才 | `C.liebian` | `C.liebian.buff_type` | 由 `OnWorkComboRules` / `OnWorkState` 的规则语义决定 | `C.liebian.price` / `C.liebian.weight` | `pawn(C.liebian)` |
| 996引擎 | `C.yinqing996` | `C.yinqing996.buff_type` | `C._game.buff_mult.output_x2` | `C.yinqing996.price` / `C.yinqing996.weight` | `pawn(C.yinqing996)` |
| 热搜包年 | `C.resou` | `C.resou.buff_type` | `C._game.buff_mult.attack_x2` | `C.resou.price` / `C.resou.weight` | `pawn(C.resou)` |
| 推送弹窗 | `C.tuisong` | `C.tuisong.buff_type` | 由 `OnWorkComboRules` / `OnWorkState` 的规则语义决定 | `C.tuisong.price` / `C.tuisong.weight` | `pawn(C.tuisong)` |
| 降价促销 | `C.jiangjia` | `C.jiangjia.buff_type` | 由 `OnWorkComboRules` / `OnWorkState` 的规则语义决定 | `C.jiangjia.price` / `C.jiangjia.weight` | `pawn(C.jiangjia)` |

### 角色专属卡

| 卡牌 | 定义 | 用途 | 价格 / 权重 | 典当 |
|---|---|---|---|---|
| 给我 | `C.geiwo` | `C.geiwo.special`：白拿购牌区一张牌 | `C.geiwo.price` / `C.geiwo.weight` | `pawn(C.geiwo)` |
| Idea | `C.idea` | `C.idea.special`：顶替一张 T1 生产卡参与升级 | `C.idea.price` / `C.idea.weight` | `pawn(C.idea)` |

## 上班角色

角色是固定规则段，不在手动调参的可编辑字段里；改角色数值请直接改 `C._roles`。开局资源缺省沿用 `C._game.start_cash` / `C._game.start_user`，倍率缩放一律向上取整（`OnWorkRoles.scale`）。

| 角色 | 开局资源 | 开局额外的卡 | 倍率 |
|---|---|---|---|
| 我是牛马 | 沿用 `C._game` | — | — |
| 我是BOSS | 沿用 `C._game` | `C._roles.boss.start_cards` | — |
| 我是运营 | `C._roles.yunying.start_cash` / `C._roles.yunying.start_user` | — | — |
| 我是HR | 沿用 `C._game` | — | 配方需求 `C._roles.hr.recipe_mult.user` |
| 我是产品经理 | 沿用 `C._game` | `C._roles.pm.start_cards` | — |
| 我是用增 | 沿用 `C._game` | — | 产出 `C._roles.yongzeng.output_mult.user` / `C._roles.yongzeng.output_mult.cash` |
| 我是财务 | 沿用 `C._game` | — | 产出 `C._roles.caiwu.output_mult.cash` / `C._roles.caiwu.output_mult.user` |
| 我是投资人 | `C._roles.touzi.start_cash` / `C._roles.touzi.start_user` | — | — |
