# 精读内容重新设计

日期: 2026-08-04

## 问题

上线的精读内容对学习者几乎没有价值。三个 episode 共 519 条,抽出的是 `Thanks so
much`、`Welcome to`、`speaking of that`、`share real stories` 这类内容。

诊断否定了「选材太简单」这个假设:Patrick Collison 访谈(平均句长 27.5 词,19% 长词)
和 Multi-GPU Kernels(2151 词种)同样只抽出寒暄和术语直译(`training data center`、
`n flops`)。**连最简单的 Easy English 素材都能抽出有价值内容**,所以根因在提取策略,
不在素材。

原提示词只说 "Extract useful English words, phrasal verbs, collocations, fixed
expressions and transferable sentence patterns",没有拒绝项、没有数量约束、没有价值
判断依据。模型于是按「表面完整性」抽取——高频、显眼、易识别。

同时发现一个更严重的硬 bug,详见「高亮定位」一节。

## 目标

用户的素材分两类,学习目标不同:

- **时事/访谈播客(native)**: native speaker 的真实语速。要解决的是**听力和阅读障碍**。
- **英语学习播客(teaching)**: 内容本身是教学。要提取的是**能直接用的口语**。

## 设计

### 1. 素材类型自动识别

导入时对转写做一次分类,不需要用户手动标注。实测三个 episode 全部判对:

| episode | 判定 | 依据 |
|---|---|---|
| Patrick Collison 访谈 | `native` | 访谈,英语是媒介不是主题 |
| Multi-GPU Kernels | `native` | "YC Paper Club special edition" |
| Easy English 播客 | `teaching` | "Say it with us, listeners." |

分类结果存在 `episodes.material_kind`,供两套提取策略分派,也供 UI 显示。

### 2. 两套提取策略

**native — 抽「会让人听漏/读错」的东西**

| 类型 | 抽什么 | 专属字段 |
|---|---|---|
| `reduction` | 快速语流中的连读弱读 | `heard_as` 实际听到的音 |
| `ellipsis` | 省略成分,需补全才能解析 | `restored` 补全形式 |
| `syntax` | 破坏解析的句法结构 | `restored` 拆解说明 |
| `idiom` | 字面推不出的比喻 | — |
| `reference` | 假定已知的人名/文化事实 | — |

实测产出(上线版本一条都没抽到):

```
[reduction] 'kind of'  heard_as: kinda   /ʌv/脱落, /d/+/ə/连读
[reduction] 'wanna'    restored: want to  /t/失爆,不定式标记消失
[ellipsis]  'I wonder a lot.'  restored: I wonder [about this] a lot
[syntax]    'transcend the plane of uh instructions...'  插入语导致主干断裂
[reference] 'cognitive L1 cache'  依赖程序员共识,非通用常识
```

`reduction` 是「听不懂 native」的真正原因:读 `want to` 没问题,听到 `/wɑnə/` 认不出。
这类在文本上看不出难度,所以原提示词永远不会抽。

**teaching — 抽「能放进学习者嘴里」的东西**

| 类型 | 抽什么 | 专属字段 |
|---|---|---|
| `phrase` | 可原样使用的口语表达 | `when_to_use` |
| `pattern` | 带 `{空位}` 的可复用句型 | `when_to_use` |
| `collocation` | 中文直译会错的搭配 | `common_mistake` |

提取时**跟随教学信号**:主播说 "a great phrase"、"we say"、"say it with us" 的地方
优先抽——这类素材本来就在告诉你什么值得学。

实测产出:

```
[pattern] 'I can't {change X}, but I can {change Y}'
          common_mistake: 中国学习者爱说 'I can't control X' — control 太绝对,
                          母语者对内在状态用 change/influence
[collocation] 'choose to see the good side'
          common_mistake: 'choose to look at' — look at 是物理性的,
                          see 才有"认知、解读"的意思
```

### 3. 数据模型

`learning_expressions` 现有字段保留 `text` / `chinese` / `pronunciation` /
`example` / `example_chinese`,新增:

- `type` — 上述 8 种类型之一,取代被压扁的 `kind`
- `heard_as` — 实际听到的音,可空
- `restored` — 补全/拆解形式,可空
- `why_hard` — 为什么会听漏读错(中文一句),native 专用,可空
- `when_to_use` — 什么场合用(中文),teaching 专用,可空
- `common_mistake` — 中式英语的错误版本,可空
- `register` — `formal` / `neutral` / `spoken` / `technical`

`kind` 的处理:上一轮为了让 iOS 能解码,把模型返的 19 种值归一成 `word/phrase/pattern`
三类,分类信息被压扁了。新的 `type` 恢复粒度。iOS 枚举同步扩充,并保留未知值兜底
(`init(from:)` fallback),避免再次出现「一个未知值让整个 bundle 解码失败」。

### 4. 卡片按类型分模板

`ExpressionInlineCard` 目前是一张双语词卡(表达/音标/中文/例句/例句翻译/跟读按钮),
装不下上面任何一个新目标。按类型分模板:

- `reduction` / `ellipsis` / `syntax`: 突出 `heard_as` 或 `restored` 的**前后对比**
  (听到的 vs 实际的),再给 `why_hard`
- `idiom` / `reference`: 意思 + 背后的意象/假定知识
- `phrase` / `pattern`: `when_to_use` + 造句练习;`pattern` 的 `{空位}` 需可视化
- `collocation`: `common_mistake` 用对比样式突出(❌ 错的 / ✅ 对的)

`common_mistake` 是信息密度最高的字段——词典给不了。

### 5. 数量与质量约束

- 每批 40 句最多 8 条,明确「宁少勿滥」
- 拒绝清单写进提示词:寒暄与节目套话、B2 已会的、可直译的领域名词
- 后端做校验:`pattern` 必须含 `{}`,IPA 只给单词且不带 `/` 包裹,
  `why_hard`/`when_to_use` 必须是中文

实测发现的三个模型不听话之处,必须由后端校验兜住:

1. 中文说明字段混入英文(探针里 8 条中 5 条)→ 校验 `why_hard` / `when_to_use` 的中文字符占比
2. `pattern` 缺 `{}` 空位(8 条里 2 条)→ 缺则降级为 `phrase`
3. IPA 偶尔多包一层 `/` → 统一剥离

### 6. 高亮定位(P0,独立于内容质量)

诊断发现的硬 bug:**936 处高亮中约 97% 指向错误的文字**。

| episode | occurrences | 精确匹配 | 指向错误文字 |
|---|---|---|---|
| 1 | 174 | 1 (0%) | 173 (99%) |
| 2 | 418 | 2 (0%) | 415 (99%) |
| 3 | 344 | 5 (1%) | 329 (95%) |

```
卡片写的是 : 'Thanks so much'
实际高亮的 : 'Okay, Patrick'

卡片写的是 : "it's really fun to do this"
实际高亮的 : ' a huge amount from Har'
```

根因:`start_offset` / `end_offset` 由模型自己数字符得出,而代码完全信任这个数字,只
校验不越界。偏移量看起来合法所以全部入库。

修法:**丢弃模型返回的 offset**,改用 `expression.text` 在宿主句里做字符串查找
(大小写不敏感、容忍空白差异),找不到就丢弃这条 occurrence。要么高亮正确,要么不高亮,
不会再指向错误文字。`sentence_position` 仍由模型给(小整数,可靠),并用「文本能否在该句
找到」交叉校验。

这一项独立于内容质量,应该先做——它是唯一让功能「不对」的 bug。

## 不做

- **不加学习者水平设置**:提示词里把门槛定高(假定 B2-C1),不引入 `AppSettings` 字段
  和后端参数。代价是无法适应不同水平用户,但避免了跨三层的配置传递。
- **不做 Library 卡片缩略图**:那是另一个需求,已单独记录。

## 迁移

现有 3 个 episode 的 519 条数据缺新字段且 offset 全错,需重新导入。每篇约 4 分钟
(learning 阶段并发后)。旧数据不做原地升级——字段是模型生成的,无法补算。

## 实施顺序

1. **P0 高亮定位**:后端自算 offset + 测试。独立可验证,先上。
2. **数据模型**:migration、schema、`type` 与新字段。
3. **两套提取策略**:素材分类 + 两套提示词 + 后端校验。
4. **iOS**:枚举扩充(带未知值兜底)、按类型分模板的卡片。
5. **重新导入**三个 episode,在模拟器里实际验证。

每步都先写失败的测试。
