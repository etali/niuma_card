# 牛马牌游戏

[![License: AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue.svg)](LICENSE)
[![Godot: 4.7.1](https://img.shields.io/badge/Godot-4.7.1-478CBF.svg?logo=godotengine&logoColor=white)](https://godotengine.org/)
[![Platforms: macOS / Web / Android](https://img.shields.io/badge/Platforms-macOS%20%7C%20Web%20%7C%20Android-606060.svg)](#4-构建打包测试)

![example](ref_image/example.png)

牛马题材的轻量卡牌对战游戏。玩家经营自己的公司，与 BOT 或另一名玩家争夺同一批市场卡牌，通过生产、升级、攻击和资源管理取得胜利。

本文记录设计思路、玩法规则、目录结构、构建与测试命令，以及使用许可。平衡分析和具体数值统一放在 [`balance.md`](balance.md)，运行时配置以 `data/` 下的 JSON 为准。

## 1. 基础的游戏设计思路

### 1.1 资源与决策

游戏只有两种基础资源：资金和用户。

- 资金是会被消耗的燃料：用于购买市场卡，也可能作为组合配方被消耗。
- 用户是留在组合中的席位：用户配方通常不会被消耗，组合成立后可持续产生收益。
- 同一批资源要在购买、生产、攻击和胜利进度之间分配，玩家每回合都要选择当前最重要的用途。

### 1.2 先组装、后兑现

一回合中的主要决策顺序是：观察市场、购买卡牌、编组、预判对手的攻击，再进入攻击和结算。组合在编组时只是摆出阵型，效果在后续阶段统一处理。

组合可以被攻击拆散；完成升级或形成带防御 Buff 的有效组合后，会进入更稳定的终局竞速。设计重点放在“成型前是否有选择和反制”，而不是在成型后继续增加复杂规则。

### 1.3 配置驱动

卡牌、组合配方、升级路线、市场权重、基础规则和 Buff 倍率均从配置读取：

- 卡牌规则：`data/cards.json`
- UI、配色、资源名称和音效：`data/ui.json`
- BOT 搜索与模拟参数：`data/bot.json`
- 平衡说明与评估口径：`balance.md`
- 单机自定义卡表：通过「选项 → 卡牌配置」选择完整的 `cards.json`，只允许修改数值字段；配置从下一局单机/BOT 对局生效。

## 2. 游戏玩法

### 2.1 胜利目标

一局游戏由两名玩家组成：`PLAYER` 与 `BOT`，联机时双方分别坐在两个座位。胜负条件由 `data/cards.json` 的 `_game` 段定义，包含资金胜利线、初始资源和资源名称。

达到资金胜利线、将对手资金降至零、或将对手用户降至零即可获胜；自己的资金或用户降至零则失败。主动购买、典当或结算不能把自己的资源直接降到失败状态，受到对手攻击则按正常失败处理。

### 2.2 回合流程

每回合按以下顺序执行：

1. **生成市场**：按照 `_game.market_size` 生成当回合公共卡位，未购买的卡不会自动保留到下一回合。
2. **行动阶段**：先手玩家完成购买和编组，后手玩家随后行动；后手可以看到先手已经摆出的阵型。
3. **自动整理**：未编组的单位卡自动归堆，组合中的卡保持自己的编组关系。
4. **攻击阶段**：攻击组合先装弹，再按攻击资源汇总成攻击池，由攻击方点选目标。
5. **结算阶段**：检查生产组合和升级组合是否仍然满足配方，满足后付款并产出。
6. **胜负检查**：若未结束则轮换先手，开始下一回合。

一张卡在同一回合只能参与一个组合；组合效果不会在行动阶段提前触发。

### 2.3 卡牌定义

每张卡由 `data/cards.json` 中的一个对象定义。常用字段如下：

| 字段 | 作用 |
|---|---|
| `name` | 显示名称 |
| `kind` | 卡牌类别：`unit`、`product`、`attack`、`buff`、`legend` |
| `tier` | 卡牌档位 |
| `price` | 市场购买价；不可购买或由升级产生的卡不单独写购买价 |
| `weight` | 市场生成权重 |
| `recipe_res` / `recipe_n` | 生产或攻击组合所需的单位资源类型与数量 |
| `output_res` / `output_n` | 生产组合产出的资源类型与数量 |
| `attack_res` / `attack_n` | 攻击组合可移除的资源类型与攻击量 |
| `upgrade_from` / `upgrade_dup_n` | 升级来源和材料份数；普通 T2 要求同名，传说接受同档任意生产卡，实际张数按路线折算 |
| `buff_type` | Buff 的行为类型 |
| `pawn` | 传说卡等特殊卡的典当值 |

卡牌对象前缀为 `_` 的键是规则段，不是可抽取卡牌。单位卡使用 `res` 标明资源类型；组合卡和 Buff 卡由 `kind` 与其余字段共同决定行为。

### 2.4 卡牌类别

- **单位卡**：资金、用户，是生产和攻击组合的基础材料。
- **生产卡**：与单位卡组合后产出资金、用户或其他卡牌。
- **攻击卡**：与单位卡组合后产生攻击点，移除对手对应类型的单位卡。
- **Buff 卡**：附着在生产或攻击组合上，改变配方填充、产出、攻击或保护效果。
- **传说卡**：由升级组合生成的终局筹码，不能作为生产或攻击发动机，也不能被攻击拆除，但可以典当。

### 2.5 购买与典当

购买市场卡需要支付资金卡，支付后的卡离开场面。购买价格读取卡牌的 `price` 字段。

典当行是桌面上的固定公共设施：可以将用户卡和其他非现金卡拖入换取资金。典当公式由 `data/cards.json` 的 `_game.pawn_rate`、`_game.pawn_user` 和卡牌的 `pawn` 字段决定；现金卡不能典当。典当不允许把自己的用户或资金降到失败状态。

**典当行**：用户卡 1 现金/张；标价 ÷2；下级材料购牌价之和 ÷2；同名下级卡×2；独角兽 30；国民应用 70；上市敲钟 100。

### 2.6 组合与结算

生产和攻击组合只有一个核心卡，可附带单位卡和 Buff 卡；升级组合只放符合路线的生产卡。每张卡每回合只能属于一个组合。

| 组合类型 | 构成 | 结算行为 |
|---|---|---|
| 生产组合 | 一张 `product` + 配方单位卡 + 可选 Buff | 产出一种资源 |
| 攻击组合 | 一张 `attack` + 配方单位卡 + 可选 Buff | 生成攻击点 |
| 升级组合 | 张数准确、满足路线要求的同档生产卡 | 消耗全部材料，生成一张升级产物，不附带资金、用户或 Buff |
| 无效组合 | 缺少核心、配方不满足或混入不允许的卡 | 不参与结算 |

配方只使用一种单位资源；一个组合只产生一种结果。组合是否有效由 `engine/combo_rules.gd` 评估，结算时会再次检查，避免卡牌在攻击阶段被移除后仍然产出。

资金配方在结算时支付并离场；用户配方作为组合席位保留。若付款后会使己方资金归零，整组作废。生产组合按结算顺序处理，先处理不需要支付资金的组合，再处理需要支付资金的组合。

### 2.7 升级

升级是纯卡面合成，不消耗资金或用户。升级路线由 `data/cards.json` 的 `_upgrade.routes` 和每张卡的 `upgrade_from`、`upgrade_dup_n` 定义：

- 两张同名 T1 仍按原路线合成对应 T2。
- 传说合成只要求材料为同档生产卡，卡名可以相同，也可以不同。T1 与 T2 不能混用。

| 传说产物 | 任意 T1 生产卡 | 任意 T2 生产卡 |
|---|---:|---:|
| 独角兽 | 恰好 4 张 | 恰好 2 张 |
| 国民应用 | 恰好 6 张 | 恰好 3 张 |
| 上市敲钟 | 恰好 8 张 | 恰好 4 张 |

少放、多放，或混入资源卡、Buff、攻击卡、传说卡，均不成立；不会自动从一堆材料中挑出子集升级。传说卡只作为升级结果或典当对象，不参与生产、攻击或后续升级。

升级目标及张数读取 `cards.json`；游戏、BOT、模拟与界面共用 `ComboRules` 的升级判定，精确张数始终是硬约束。

### 2.8 Buff

Buff 是否生效由 `buff_type` 决定，倍率和行为参数由 `_game.buff_mult` 等配置提供。当前行为类别包括：

- `user_fill`：满足条件时降低用户配方的实际填充要求。
- `output_x2`：使生产产出按配置倍率计算。
- `attack_x2`：使攻击量按配置倍率计算。
- `protect_user`：保护组合所需的用户配方卡。
- `protect_cash`：保护组合所需的资金配方卡。

Buff 必须和一个有效核心组合在同一组中才会生效；保护额度只覆盖配方需要的单位卡，富余单位卡仍可被攻击。

同一组中的数值 Buff 按张数叠乘：默认倍率下，两张 996 引擎使产出变为 4 倍，三张为 8 倍；热搜包年同理叠乘攻击量。两类倍率互不混用。裂变补满和资源保护属于状态，多张不会重复扩大其效果；同一张实体卡不能重复计数。

### 2.9 攻击

攻击阶段先为攻击组合装弹，再把攻击量按目标资源汇总成攻击池。攻击池只能攻击对应类型的单位卡：

- 散牌、组合中的富余单位卡和配方单位卡都可以成为目标。
- 移除配方所需的任意一张单位卡，可能使整个组合在结算时失效。
- 受保护的配方单位卡、组合核心、Buff 卡和传说卡不能被直接攻击。
- 一旦开始攻击某个组合，剩余攻击点会锁定在该组合上；攻击点不足以继续选择目标时结束。
- 攻击把对手资金或用户降至零时立即结束并判胜。

攻击目标、攻击锁和攻击结果由 `GameState`、`ComboRules` 与 `engine/settle.gd` 共同维护，界面、BOT、模拟器和联网服务器使用同一套规则。

### 2.10 自定义卡表、BOT、录像与联机

「选项 → 卡牌配置」可以点击选择，或直接把 `cards.json` 从文件管理器拖到拖放区域。它必须与默认卡表保持相同的卡牌集合、卡牌语义、升级路线、Buff、胜负条件和固定规则，只能改变允许的数值字段。选择后不会修改当前对局，点击“应用并重开”后从下一局单机或 BOT 对局生效；配置路径保存在本地用户偏好中。

旧卡表里的 `_comment`、`_note` 说明文字不会影响兼容性；实际规则字段仍严格校验。旧配置也使用当前游戏规则，因此更新升级规则后需要重新评估，历史结果不会改写。

可编辑字段、数值边界和固定规则由 `data/card_config_schema.json` 声明；游戏与无头评估共用 `engine/card_config_rules.gd`，Python 工作台读取同一规格，共享契约样例验证三个入口。每次开局重新校验选中的文件。

手动调参网页的“导出 cards.json…”直接输出完整卡表，可选择项目的 `data/cards.json` 进行替换。工作台保存的 `reports/manual_balance/configs/<配置ID>.json` 也使用同一纯卡表格式；版本名称等信息另存在 `config_meta/`，备注和评估按原配置 ID 关联。旧封装文件会在工作台启动时转换，卡牌参数保持不变。

桌面启动可传 `--cards-config=/absolute/path/cards.json`（含空格的路径将整个参数用引号包住）。它在本次进程中优先于已保存的卡表选择，单机重开仍使用指定文件，不改用户偏好；路径或内容无效时明确报错。手动调参网页的“保存并以当前配置启动游戏”会先保存当前配置及备注，再保存卡表快照并使用此参数打开游戏，试玩不新增评估记录。出售价格使用卡牌的 `pawn` 字段，可填非负整数；未设置的卡牌继续沿用游戏原有计算规则。

联网对局始终使用内置 `res://data/cards.json`。当前单机局若用了自定义卡表，需要先恢复默认并重开，才能建立或加入房间；等待对手期间保留原局规则。联网和录像播放期间“卡牌配置”页会锁定，录像需先退出再开始新局。


BOT 当前实现由 `data/bot.json` 选择模型和搜索强度，策略实现位于 `engine/bot_*.gd`。BOT 通过与真人相同的购买、编组、攻击和结算接口行动。

录像保存行动和规则指纹，可在游戏内回放；回放使用正式对局的结算和动画路径。底栏可输入行动步数并按回车或点击“跳转”，范围为 0～总行动步数，0 表示初始局面；计数与“上一步／下一步”一致，同一摞连续攻击算一步。每次保存使用独立文件名，已有录像不会被同名保存覆盖。配置偏好通过临时文件完整写入后替换，保存失败会明确提示并保留原选择。

网络规则指纹包括卡牌、游戏规则和升级规则；旧录像只有保存的完整规则一致时才迁移旧指纹。

联机恢复使用独立于动画展示状态的服务器检查点，包含同一版本的快照、阶段、行动方和序号；重连按当前阶段继续，主机接管保留已经确认的结算进度。当前协议版本为 10，双方需使用同版本构建；该版本统一对手座位标识为 bot，并沿用同类数值 Buff 按张数叠乘的规则。

## 3. 文件目录结构

以下列出主要目录、配置、文档和操作入口，各模块内的源文件不逐一展开。

```text
.
├── data/
│   ├── cards.json              # 卡牌、组合、升级和基础规则
│   ├── card_config_schema.json # 自定义卡表的可编辑字段、数值边界和固定规则
│   ├── ui.json                 # UI、配色、资源名称、音效映射
│   └── bot.json                 # BOT 与无头模拟参数
├── engine/                     # 规则、状态、结算、BOT、录像、配置与持久化
├── net/                        # 联机房间、传输、服务器和协议
├── scenes/                     # Godot 场景、牌桌、设置、规则书与 Web 文件交互
├── shaders/                    # 卡面和特效着色器
├── assets/                     # 随源码提供的卡面、图标、字体和音效
├── tests/                      # GDScript、Python、JavaScript 回归测试及夹具
├── tools/                      # 构建、检查、模拟、调参、发布和诊断工具
├── project.godot               # Godot 项目设置
├── export_presets.cfg          # macOS、Web、Android APK/AAB 导出预设
├── README.md                   # 项目说明、玩法、操作入口和许可说明
├── LICENSE                     # AGPL v3 标准许可证全文
├── NOTICE                      # 项目来源与许可标识
├── balance.md                  # 平衡分析和具体数值说明
├── bot.md                       # BOT 实现与评估说明
├── 构建游戏.command            # 构建 macOS App / Android 包
├── 启动游戏.command            # 启动已构建 App
├── 安装安卓构建环境.command    # 安装 Android SDK、JDK 和导出模板
├── 打包DMG.command             # 将已编译的 macOS App 制作成 DMG 安装盘
├── 本地运行Web版.command       # 本地启动 Web 版及联机服务
├── 打包发布.command            # 导出并生成 Web、macOS 发布压缩包
└── 启动手动调参.command        # 启动卡表调参与评估工作台
```

`assets/art/` 的卡面与角色图、`assets/android/` 的图标与启动图均由 Git 管理，克隆仓库即包含运行所需素材。素材旁的 `.import` 文件保存 Godot 导入设置与资源标识，应随素材提交；`.godot/` 中的导入缓存由 Godot 重新生成，不提交。构建输出和本地用户存档也不作为源码提交。

单机牌桌和无头 `Transport` 使用 `engine/round_flow.gd` 编排攻击、生产与回合收尾；牌桌通过回调插入输入和演出，裁决统一经过 `IntentApply`。联网客户端消费服务器结果，回执被拒时保留阶段并恢复输入。重开、切局与退出会使旧会话失效，旧的思考、网络和动画回调不能推进新局。

配方预览、付款和归零保护读取同一组合评估结果；自动整理只改变视觉归堆，组合关系、配方进度和 Buff 状态由界面展示。战报保存规则事件和资源结果，显示名称由当前界面生成。

`tmp/`、`tools/` 和 `tests/` 用各自的 `.gdignore` 排除 Godot 编辑器扫描，避免生成临时图片的 `.import` 和开发、测试脚本的 `.uid`。`tools/` 与 `tests/` 的纯 GDScript 脚本仍可在本项目使用的 Godot 4.7 中通过 `--script` 按路径运行，JSON 夹具直接按文件读取；这些目录不应放游戏运行时需要的导入资源或全局 `class_name`。正式游戏脚本与着色器的 `.uid` 是资源稳定标识，应继续保留并提交。

## 4. 构建、打包、测试

以下命令默认在仓库根目录执行。Godot 路径可用 `GODOT=/path/to/Godot` 覆盖。首次用 Godot 打开工程或运行构建入口时，会导入仓库内的素材并生成本地缓存。

### 4.1 构建和启动 macOS 版

```bash
./构建游戏.command
./启动游戏.command
```

启动脚本发现 `build/牛马牌.app` 不存在时会先构建。常用参数：

```bash
./启动游戏.command --rebuild       # 重新构建后启动
./启动游戏.command --rebuild "--cards-config=/absolute/path/cards.json" # 指定卡表试玩
./启动游戏.command 2                # 启动两个独立窗口
./启动游戏.command 2 --room=TEST    # 本机开房并让其余窗口加入同一房间
```

构建脚本还支持：

```bash
./构建游戏.command --help
./构建游戏.command --engine-plan
./构建游戏.command --slim-engine
./构建游戏.command --slim-engine --arch arm64 --jobs 8
```

`--engine-plan` 只扫描精简引擎计划；`--slim-engine` 会构建精简模板并导出 App。构建日志保存在 `build/logs/`。

制作 DMG 安装盘：

```bash
./打包DMG.command
./打包DMG.command --app "/path/to/牛马牌.app" --output "/path/to/牛马牌.dmg"
```

默认读取已编译的 `build/牛马牌.app`，输出 `build/牛马牌.dmg`。双击 DMG 后，将应用拖到盘内的“Applications”入口即可安装。打包过程保留 App 的权限和符号链接，校验新镜像成功后才替换已有安装包；日志保存在 `build/logs/`。

### 4.2 Android

先安装匹配 Godot 版本的 Android 依赖：

```bash
./安装安卓构建环境.command --dry-run
./安装安卓构建环境.command
```

导出包：

```bash
./构建游戏.command --android-debug   # debug APK
./构建游戏.command --android         # release APK
./构建游戏.command --aab             # Google Play AAB
```

首次构建发布包且未配置签名时，脚本会用 JDK `keytool` 生成独立的 release keystore，保存在项目的 `.android-signing/`（密钥和密码配置均不进 Git）。后续 APK/AAB 复用同一签名；请备份整个目录，清理 `build/` 或 `.godot/` 不影响它，换电脑构建时需一起迁移。

已有发布签名时，可在 Godot 对应 Android 导出预设中填写 `Keystore / Release`、`Release User`（密钥别名）、`Release Password`，或设置 `GODOT_ANDROID_KEYSTORE_RELEASE_PATH`、`GODOT_ANDROID_KEYSTORE_RELEASE_USER`、`GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD` 环境变量。脚本优先使用这些配置；配置缺项或密钥文件丢失会提前报错，不会生成新密钥替换。密钥密码和密钥库密码须一致。已有发行版本应继续使用原签名。

APK 导出后会用 `apksigner verify` 验证签名，通过后才替换最终产物，避免失败导出留下未签名包。Android 使用完整横屏牌桌，不使用 macOS 桌面抽屉模式。

Android 包名为 `com.astra.niumacard`，APK 和 AAB 使用同一包名。

#### Android 真机调试

首次安装完成后，先加载工具链环境并确认手机已连接：

```bash
source build/android-env.sh
export PATH="$ANDROID_HOME/build-tools/36.1.0:$PATH"
adb devices -l
```

手机端开启“开发者选项 → USB 调试”，用数据线连接并解锁手机；第一次连接时在手机上允许 USB 调试授权。当前 debug APK 是 `arm64-v8a`，测试设备需要支持 ARM64。

安装、启动和查看日志：

```bash
./构建游戏.command --android-debug
adb -d install -r build/牛马牌-debug.apk
adb -d shell monkey -p com.astra.niumacard 1
adb -d logcat -c
adb -d logcat | tee build/logs/android-device.log
```

如果新包名的版本仍提示签名冲突，确认不需要其本地数据后，执行 `adb -d uninstall com.astra.niumacard` 再安装；卸载会删除该应用的本地数据。停止日志用 `Control+C`。没有设备连接时，构建仍可完成，但不能做真机验证；`adb devices` 显示 `unauthorized` 时，需要回手机确认授权，显示 `offline` 时重新插拔数据线或重启 adb。

### 4.3 Web 与发布包

```bash
./打包发布.command
./本地运行Web版.command       # 本地单机 Web
./本地运行Web版.command 2     # 启动专服并打开两个联机标签
```

`打包发布.command` 固定生成 `build/牛马牌_web.zip` 和 `build/牛马牌_mac.zip`，首次运行可能需要下载 Godot Web 导出模板；下载和解压通过完整性验证后才安装，失败可直接重试。Web 版必须通过本地 HTTP 服务访问，不能直接双击 `index.html`。

项目不再手动设定应用版本，产物文件名也不带版本后缀。平台要求的内部版本字段由 Godot 使用默认值填充。

Web 使用常驻完整牌桌，复用规则书、选项、静音和录像入口；卡表和录像通过浏览器文件选择导入，保存录像会下载 JSON。静音偏好会跨场景和启动保留。

同一工作区的构建资源事务互斥，字体子集化、导入、导出和恢复不会交叠。素材导入失败会保留错误输出并以失败退出。

维护素材时可继续使用 `tools/build_art.py` 和 `tools/build_android_icons.py` 等生成工具。修改后的素材、清单与对应 `.import` 导入设置一起提交到 Git，游戏构建和发布会使用仓库中的素材。

新版卡牌直接覆盖 `assets/art/icon/icon_*.png`，通过 `data/ui.json` 的 `art.illustrations` 登记。29 张功能卡使用透明手绘简笔画；现金牌用没有表情的单枚硬币与 ¥ 符号，用户牌用呆萌圆头、豆形身体和线条四肢的全身小人；两者均采用不规则墨线和奶油色填充。资源牌主图、配方和产出图标共用 `assets/art/icon/icon_cash.png` 与 `icon_user.png`，仅显示尺寸不同；对应 SVG 仅作为可编辑源稿；资源牌没有底部配方和产出，主图向下居中平衡留白。插画中的金币和用户统一参考这两份资源图标，人物姿势和情绪随场景变化；运行时没有另一套旧卡牌素材。素材由内置 ImageGen 生成，风格参考《Stacklands》的简洁手绘感觉，插画以关键物件和动作为主体，需要人物时使用无身份特征的圆头小人，完整生成提示词保存在 `assets/art/icon/prompts.json`。`tools/build_art.py` 重建素材时会保留新版图标和插画登记，不会将新版覆盖回旧线稿。

底板按功能分色：现金为黄、用户为蓝、变现为草绿、拉新为较深的蓝、传奇为白金、攻击为橙、增强为紫、防御为灰绿。卡面、卡背及典当行的全部运行时颜色均由 `data/ui.json.palette` 提供，通过现有 `Palette` 取色、保存、恢复和广播刷新；素材清单不再保存这些颜色。

牌桌使用暖灰绿再生纸纤维、低对比折痕，以及用户追钱、摸头、抱金币、被现金砸哭和被张嘴金币追赶等简笔画的较密的无缝重复墨线纹理（`assets/art/table/user_cash_pattern.svg`）；配合带折角的手绘理牌垫；理牌垫保持空净，双方身份由顶栏说明。购牌区采用纸板长条和固定手绘卡槽，典当行以短线分隔。价格以一端收尖、带圆孔与细绳的五边形长吊牌挂在卡牌右下角，金币图标共用现金牌贴图，图标与数字按实际绘制尺寸组成紧凑居中的价格行，统一留白。商品悬停时卡牌和吊牌一起轻抬，足额现金拖入时价签边缘反馈，成交时吊牌轻弹淡出；装饰不参与碰撞或购买规则。所有颜色仍由现有 `Palette` 配置及取色逻辑提供。

选项菜单中的“UI”统一收纳显示与配色设置。“UI → 配色 → 背景纹理”可实时调整密度、图案间隔及纹理颜色；密度越大则重复次数越多，间隔控制平铺单元的额外留白。默认值在 `data/ui.json.palette.pattern`，与现有配色共用保存和还原逻辑，保存至 `user://palette.json`。

状态覆盖图直接维护在 `assets/art/overlay/overlay_shield.png` 与 `overlay_void_stamp.png`：护盾使用粗墨线浅蓝盾牌及奶油色勾，位于标题带下方；作废框中心透明，与独立文字一起倾斜，颜色跟随 `Palette.semantic("danger")`。两张图由内置 ImageGen 重绘，提示词记录在 `assets/art/overlay/prompts.json`，旧素材重建会保留已登记的新版。

游戏图标使用用户牌同款全身小人，姿势为无辜地抬手摸头。可编辑源稿为 `assets/art/app_icon.svg`；运行 `Godot --headless --path . --script tools/export_app_icon.gd` 导出 `assets/art/app_icon.png`、`assets/app_icon.png` 及现金/用户共享 PNG，再运行 `python3 tools/build_android_icons.py` 更新 Android 图标和启动图。游戏标题、抽屉角色、结算界面与各平台应用图标共用这套形象。

用 `Godot -s tools/visual_preview.gd -- --render /绝对路径/cards.png` 查看正式卡面的七卡样张；末尾加 `--all` 可查看全套卡牌。卡面仅保留卡名、插画与资源数值，按“配方 → 结果”排列；用途和消耗规则放在悬停说明，显示当前材料缺口、有效产出及资源消耗时机。插画事件动作和生产、升级、攻击回执共用真实对局结果，仅作用于表现层。

### 4.4 联机专服

```bash
"$GODOT" --headless -s tools/pvp_server.gd --port=8910
"$GODOT" --headless -s tools/pvp_server.gd --port=8910 --seed=12345 --verbose-net
```

服务器启动后会打印本机和局域网连接地址。客户端使用相同房间码连接；`--seed` 仅用于复现牌序，`--verbose-net` 用于查看网络收发。

### 4.5 测试

运行全部回归测试：

```bash
tools/run_tests.sh
```

入口自动发现 `tests/test_*.gd` 和 `tests/test_*.py`，再执行文档/脚本静态检查；
手动调参的 Python 测试包含 Node 网页行为回归。需要 Python 3、Pillow、fonttools、Node.js
和匹配项目版本的 Godot。报告分别统计 GDScript 断言、Python 用例和静态检查，跳过用例单独列出。

只运行匹配名称的测试：

```bash
tools/run_tests.sh arrivals
TEST_SPEED=1 tools/run_tests.sh
tools/run_tests.sh android_signing
JOBS=4 TEST_TIMEOUT=180 tools/run_tests.sh --log-dir build/test-results/local
```

筛选没有匹配项时返回失败。每个测试默认最多运行 180 秒，超时或取消会停止其进程与子进程；
详细日志和 `results.json` 保存在打印出的 `build/test-results/` 目录。每个 Godot 进程使用临时
项目入口和独立用户数据目录，Python 测试启动的游戏进程也继承此隔离，不覆盖玩家设置。

构建、测试和评估报告中的项目文件路径以项目根目录为基准，家目录内的其他位置显示为 `~/…`。
工具输出与归档日志会移除本机项目目录和家目录前缀；SDK 和签名配置仍保留实际运行所需的路径。

单独运行某个 GDScript 测试：

```bash
"$GODOT" --headless -s tests/test_engine.gd
```

直接单跑时，继承 `tests/harness.gd` 的测试也会隔离 `user://`；完整超时、日志和子进程
清理请使用统一入口。

常用静态检查和发布验证：

```bash
python3 tools/check_card_table.py
python3 tools/check_doc_refs.py
python3 tools/check_card_values.py
python3 tools/check_art_assets.py
python3 tools/verify_release.py build/牛马牌.app
```

无头对局和手动数值评估：

```bash
"$GODOT" --headless -s tools/balance_report.gd 500 baseline
./tools/bot_duel.sh 50 bot:1 bot:0 1001 tmp/bot-duel.json
# 推荐：双击项目根目录「启动手动调参.command」
# 命令行评估：tools/eval.sh /absolute/path/manual-request.json
```

手动调参工具支持同时提交多项评估，每项使用独立 Godot 进程，保存自己的进度、卡表快照和逐局数据。在“评估记录”的对应行点击“停止模拟”，只停止该项任务。“保存并运行当前配置”左侧的“仅保存配置”只保存当前配置及备注，不启动模拟或游戏。名称和卡牌参数均未修改时复用原配置；创建新配置需要未使用的新名称和修改后的卡牌参数，保存、评估与试玩沿用同一套配置校验。指标口径与使用方式见 `balance.md`。

测试和检查均以退出码表示成功或失败；出现空输出时应继续查看脚本退出码、日志和对应测试文件，而不要据此判断“没有问题”。

## 5. 使用许可

本项目采用 [GNU Affero General Public License v3.0](LICENSE)，仅第 3 版（`AGPL-3.0-only`）。许可证使用 [SPDX 收录的标准全文](https://spdx.org/licenses/AGPL-3.0-only.html)，未添加额外限制。以下为使用说明，具体权利和义务以 `LICENSE` 为准。

- **允许商用**：可按许可证使用、修改和分发本项目，包括商业用途；遵守 AGPL v3 不需要另行购买商业授权。
- **分发与源码**：分发时须保留适用的版权、许可和免责说明，附上许可证，并按条款提供相应源码。分发受许可约束的修改版本时，须说明修改情况并继续遵守 AGPL v3。
- **网络交互**：如果修改本项目并让用户通过网络与修改后的版本交互，须按第 13 条向这些用户显著提供免费获取该版本相应源码的途径。
- **项目来源**：[NOTICE](NOTICE) 记录项目名称“牛马牌（useup_money）”和原仓库链接，不增加标准许可证之外的使用限制。

项目自有源文件使用以下简短声明，注释符号按文件语言调整；可执行脚本的 shebang 保留在首行：

```python
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.
```

本许可仅适用于维护者有权授权的项目内容。Godot 引擎、Noto 字体及其他第三方代码或素材继续适用各自的许可证；其中 `assets/fonts/NotoSansSC.ttf` 适用 SIL Open Font License 1.1。

选项面板统一位于顶部横条下方的右上角，并限制在上下横条之间；长内容使用内部滚动（读入录像与局域网对战保留独立流程）。保存录像后的结果与可复制路径留在原“存录像”页。

UI 页底部统一提供“保存”和“还原默认”，作用于窗口比例、透视、牌桌缩放、入口大小、配色与背景纹理。显示偏好写入 `user://ui_preferences.json`，配色沿用 `user://palette.json`；下次启动读取。独立的“还原全桌”按钮已移除。价签与牌角分开留白，绳环连接卡角绳结和吊牌圆孔。
