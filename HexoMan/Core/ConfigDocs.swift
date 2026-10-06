//
//  ConfigDocs.swift
//  HexoMan
//
//  配置项的「填写文档」。解决的是新手最常见的困境：
//
//  界面上写着 `license`，值是 `by-nc-sa`，文档只说了「许可证」，
//  但没人知道 by / nc / sa / nd 分别意味着什么、该选哪个——
//  而选错的后果是**法律层面的**：图片和文章可以被商用、可以被改作，
//  别人的站点转载你也不用标注。选错不是丑，是把自己的东西交出去了。
//
//  所以这里对每个**枚举型/选项型**配置给全量候选 + 每个值的中文后果说明，
//  而不是让用户去搜「by-nc-sa 是什么意思」。普通文本型则给格式、例子和常见坑。
//
//  查找分三层，从具体到通用：
//  1. `nested` —— 按「父键.子键」查。`creative_commons.license` 和顶层的
//     `license` 语义完全不同，这一层专门解决「同一个键名、不同含义」。
//  2. `flat` —— 按顶层键名查。
//  3. `generic` —— 按值形状兜底（颜色 / 网址 / 图片路径），
//     保证没收录的键也能拿到格式说明，而不是一片空白。
//

import Foundation

// MARK: - 文档结构

/// 一个配置项的详细填写文档。
struct ConfigDoc {

    /// 一句话：这个东西是干什么的。
    var summary: String

    /// 详细说明：可以多段。
    var detail: String

    /// 怎么填：格式规则、要不要引号、留空会怎样。
    var howToFill: String?

    /// 可以直接抄的示例值。
    var examples: [String]

    /// 候选项 + **每个值的中文后果**。有这一项时控件应当用下拉。
    ///
    /// label 直接展示给用户，所以必须写成「值 + 人话」，
    /// 不能只写 `by-nc-sa`。
    var options: [ConfigField.Option]

    /// 容易踩的坑。
    var tip: String?

    /// 延伸阅读。
    var links: [Link]

    struct Link {
        var label: String
        var url: String
    }

    init(
        summary: String,
        detail: String = "",
        howToFill: String? = nil,
        examples: [String] = [],
        options: [ConfigField.Option] = [],
        tip: String? = nil,
        links: [Link] = []
    ) {
        self.summary = summary
        self.detail = detail
        self.howToFill = howToFill
        self.examples = examples
        self.options = options
        self.tip = tip
        self.links = links
    }

    var isEmpty: Bool {
        detail.isEmpty && howToFill == nil && examples.isEmpty && options.isEmpty && tip == nil
    }
}

// MARK: - 文档库

enum ConfigDocs {

    // MARK: 嵌套文档：父键 → 子键 → 文档

    /// **按父键分组**的子项文档。
    ///
    /// 为什么不放一张扁平的 `key → doc` 表里：
    /// `license` 单独看没有意义，必须知道它挂在 `creative_commons` 下面。
    /// 同样 `url` 在 `avatar` 下是图片路径、在 `menu` 下是跳转地址。
    static let nested: [String: [String: ConfigDoc]] = [

        // ---- creative_commons：CC 许可证 ----
        "creative_commons": [
            "license": ConfigDoc(
                summary: "文章使用的知识共享（Creative Commons）许可证代号。",
                detail: """
                这决定别人拿走你的文章、图片、代码之后**可以做什么**。\
                代号由几段拼起来，每一段都收紧一层权利：

                by（署名）— 必须写明原作者。
                nc（非商业性）— 别人不能拿你的内容去盈利。
                nd（禁止演绎）— 别人不能修改你的内容。
                sa（相同方式共享）— 别人改了之后也必须用同样的协议发布。
                zero — 公有领域，完全放弃权利，别人可以随便用。

                不确定就用 **by-nc-sa**（最常被推荐、最保守的那个）：
                别人可以转载和翻译并标注出处，但不能商用、不能改、
                改了还得同样开放授权。
                """,
                howToFill: "从下拉里选，不要手填。填错大小写或写成中文会导致文章底部的版权链接失效。",
                examples: ["by-nc-sa"],
                options: [
                    .init(value: "by-nc-sa", label: "by-nc-sa — 署名 + 非商业 + 相同方式共享（最常推荐）"),
                    .init(value: "by-nc-nd", label: "by-nc-nd — 署名 + 非商业 + 禁止修改（最严格）"),
                    .init(value: "by-sa", label: "by-sa — 署名 + 相同方式共享（允许商用）"),
                    .init(value: "by-nc", label: "by-nc — 署名 + 非商业（允许修改）"),
                    .init(value: "by-nd", label: "by-nd — 署名 + 禁止修改（允许商用）"),
                    .init(value: "by", label: "by — 只要求署名（最宽松）"),
                    .init(value: "zero", label: "zero — 公有领域 CC0，放弃所有权利（声明式，实际不可撤回）")
                ],
                tip: "许可证只对「你愿意授权出去的东西」有意义。如果文章完全不想被转载，正确做法是别发布，而不是指望读者读许可证。",
                links: [
                    .init(label: "六种 CC 许可证对照（官方）", url: "https://creativecommons.org/share-your-work/cclicenses/")
                ]
            ),
            "language": ConfigDoc(
                summary: "CC 许可证说明页的语言版本。",
                detail: "决定文章底部「知识共享许可协议」链接打开后显示哪种语言的许可证正文。不是站点界面语言——站点语言改顶层的 `language`。",
                howToFill: "填 `deed.` 开头的代码。找不到对应语言时留空即可，会自动回退到英文。",
                examples: ["deed.zh"],
                options: [
                    .init(value: "deed.zh", label: "deed.zh — 简体中文"),
                    .init(value: "deed.zh-hant", label: "deed.zh-hant — 繁體中文"),
                    .init(value: "deed.en", label: "deed.en — 英文"),
                    .init(value: "deed.ja", label: "deed.ja — 日文"),
                    .init(value: "deed.ko", label: "deed.ko — 韩文"),
                    .init(value: "deed.fr", label: "deed.fr — 法文"),
                    .init(value: "deed.de", label: "deed.de — 德文"),
                    .init(value: "deed.es", label: "deed.es — 西班牙文")
                ],
                tip: "CC 官方一共提供 39 种语言；下拉里没有的话照 `deed.` + 语言代码的规律填即可，例如荷兰语是 `deed.nl`。"
            ),
            "post": ConfigDoc(
                summary: "是否在每篇文章底部显示 CC 版权声明。",
                detail: "开启后，每篇文章末尾会出现署名作者、原文链接和 CC 许可证图标。关闭则整篇文章不显示版权块。",
                howToFill: "开或关即可。",
                examples: ["true"]
            ),
            "clipboard": ConfigDoc(
                summary: "复制全文时是否附带版权署名。",
                detail: "开启后，用户在文章页点「复制」会连同作者名和原文链接一起复制进剪贴板。适合转载量大的内容站。",
                howToFill: "开或关即可。",
                examples: ["false"],
                tip: "这个功能依赖站点已配置好站点网址 `url`，否则复制出来的链接是残缺的。"
            )
        ],

        // ---- footer：页脚 ----
        "footer": [
            "since": ConfigDoc(
                summary: "页脚版权年份的起始年，显示成「2026 - 2026」。",
                detail: "填你开始写博客的年份。年份是动态取的：到了下一年会自动变成「2026 - 2027」，不用回来改。",
                howToFill: "四位数的年份数字，例如 2020。",
                examples: ["2020"],
                tip: "刚开站、只有一年就填当前年份即可，会显示成单年。"
            ),
            "powered": ConfigDoc(
                summary: "页脚底部的框架标注（通常是「Powered by Hexo」）。",
                detail: "Hexo 生成的站点默认会标注使用的框架，这是开源项目的常见礼节，一般建议保留。",
                howToFill: "这一项下面还有子项 enable（是否显示），切到「原始文件」页可以改。"
            )
        ],

        // ---- post_meta：文章信息行 ----
        "post_meta": [
            "item_text": ConfigDoc(
                summary: "文章信息行里是否显示「共 N 篇文章」这类统计文字。",
                detail: "",
                howToFill: "开或关即可。",
                examples: ["false"]
            ),
            "created_at": ConfigDoc(
                summary: "是否显示文章创建日期。",
                detail: "",
                howToFill: "开或关即可。",
                examples: ["true"]
            ),
            "updated_at": ConfigDoc(
                summary: "是否显示最后更新时间。",
                detail: "以文件的修改时间为准。文章改过之后这个时间会变——如果你只微调错别字却不想让人看到更新时间，可以关掉。",
                howToFill: "开或关即可。",
                examples: ["true"],
                tip: "更新时间的取值方式由顶层的 `updated_option` 决定（文件时间 / 文章日期 / 不显示）。"
            ),
            "categories": ConfigDoc(
                summary: "是否显示所属分类。",
                detail: "",
                howToFill: "开或关即可。",
                examples: ["true"]
            ),
            "tags": ConfigDoc(
                summary: "是否显示文章标签。",
                detail: "",
                howToFill: "开或关即可。",
                examples: ["true"]
            )
        ],

        // ---- codeblock：代码块 ----
        "codeblock": [
            "copy_btn": ConfigDoc(
                summary: "代码块右上角是否显示「复制」按钮。",
                detail: "技术博客强烈建议开启。读者复制命令时不用手动框选。",
                howToFill: "开或关即可。",
                examples: ["true"]
            )
        ],

        // ---- bg_image：背景图 ----
        "bg_image": [
            "enable": ConfigDoc(
                summary: "是否启用站点背景图。",
                detail: "开启后站点内容区背后铺一张图。亮色和暗色模式可以各用一张。",
                howToFill: "开或关即可。",
                examples: ["true"]
            ),
            "url": ConfigDoc(
                summary: "亮色模式下的背景图地址。",
                detail: "图片放在站点 `source/images/` 目录下，引用时写 `/images/文件名`。也可以填外部网址。",
                howToFill: "站内图片写 `/images/bg/bg-light.webp`；外链写完整 https 网址。",
                examples: ["/images/bg/bg-light.webp", "https://cdn.example.com/bg.jpg"],
                tip: "背景图建议用体积小的模糊或纯色图。铺一张几 MB 的大图会让首屏明显变慢。"
            ),
            "dark": ConfigDoc(
                summary: "暗色模式下的背景图地址。",
                detail: "留空则暗色模式下沿用亮色的那张图。",
                howToFill: "同 `url`，站内路径写 `/images/` 开头。",
                examples: ["/images/bg/bg-dark.webp"]
            ),
            "opacity": ConfigDoc(
                summary: "背景图的不透明度，0 表示全透明（等于没有）。",
                detail: "图片太抢眼时调低这个值，正文会更容易读。",
                howToFill: "0 到 1 之间的小数。0.1 几乎看不见，1 是完全不透明。",
                examples: ["1", "0.3"]
            )
        ],

        // ---- say：一言 ----
        "say": [
            "enable": ConfigDoc(
                summary: "是否显示「每日一言」。",
                detail: "在首页顶部随机显示一句格言。纯装饰，但很多中文博客都有。",
                howToFill: "开或关即可。",
                examples: ["true"],
                tip: "一言依赖外部接口，接口挂了就一直显示不出来。不想要外部依赖建议关掉。"
            ),
            "api": ConfigDoc(
                summary: "每日一言的接口地址。",
                detail: "填一个返回 JSON 的地址。默认那个是公开接口，随时可能失效，失效时一言就空白。",
                howToFill: "完整的 https 网址，以 / 结尾与否都行。",
                examples: ["https://el-bot-api.vercel.app/api/words/young"],
                tip: "接口失效是最常见的「一言不见了」原因。换一个可用接口即可。"
            )
        ],

        // ---- local_search：本地搜索 ----
        "local_search": [
            "enable": ConfigDoc(
                summary: "是否启用站内搜索。",
                detail: "开启后会在每篇文章底部生成一份搜索索引文件（体积大致随文章数增长）。",
                howToFill: "开或关即可。",
                examples: ["true"],
                tip: "这个功能依赖 `hexo-generator-searchdb` 插件。没装的话开了也不会有搜索框。"
            ),
            "trigger": ConfigDoc(
                summary: "搜索框什么时候出现。",
                detail: "`auto` 是自动在页面上放一个输入框；`manual` 则不自动放，需要你自己在模板里放按钮。",
                howToFill: "auto 或 manual。",
                examples: ["auto"],
                options: [
                    .init(value: "auto", label: "auto — 自动显示搜索框（推荐）"),
                    .init(value: "manual", label: "manual — 不自动显示，由你自己放触发按钮")
                ]
            ),
            "top_n_per_article": ConfigDoc(
                summary: "每篇文章在搜索结果里最多显示几条相关摘要。",
                detail: "数字越大搜索结果越详细，同时索引文件也越大。",
                howToFill: "正整数。1 是最省体积的设置。",
                examples: ["1"],
                tip: "文章多（几百篇以上）时保持 1 或 2，否则生成的索引文件会明显变大、拖慢搜索。"
            ),
            "unescape": ConfigDoc(
                summary: "搜索时是否还原 HTML 转义字符。",
                detail: "",
                howToFill: "开或关即可。",
                examples: ["false"]
            ),
            "preload": ConfigDoc(
                summary: "是否在页面加载时就预取整个索引。",
                detail: "开启搜索响应更快，但会占更多流量。文章少的时候才值得开。",
                howToFill: "开或关即可。",
                examples: ["false"]
            )
        ],

        // ---- search ----
        "search": [
            "modal": ConfigDoc(
                summary: "搜索框是弹窗形式还是常驻在页面上。",
                detail: "",
                howToFill: "开或关即可。",
                examples: ["true"]
            ),
            "bg_image": ConfigDoc(
                summary: "搜索弹窗背景图。",
                detail: "留空则用默认背景。",
                howToFill: "站内图片写 `/images/` 开头，外链写完整网址。",
                examples: ["https://cdn.example.com/bg/search.jpg"]
            )
        ],

        // ---- vendors：CDN ----
        "vendors": [
            "host": ConfigDoc(
                summary: "第三方依赖（字体、图标库等）的 CDN 前缀。",
                detail: "主题把一些大文件放在 CDN 上加载，避免每次都从自己的服务器取。",
                howToFill: "以 / 结尾的 CDN 地址。",
                examples: ["https://fastly.jsdelivr.net/npm/"],
                tip: "如果你的访客主要在国内，jsdelivr 的主域名经常被干扰，换成镜像或 fastly 地址更稳。改这个不需要重新生成，直接刷新即可。"
            )
        ],

        // ---- lazyload / scrollreveal / fireworks ----
        "lazyload": [
            "enable": ConfigDoc(
                summary: "图片是否懒加载（滚到才加载）。",
                detail: "首屏只加载看得见的图片，页面打开更快。",
                howToFill: "开或关即可。",
                examples: ["true"]
            )
        ],
        "scrollreveal": [
            "enable": ConfigDoc(
                summary: "元素滚动到视口时是否做浮现动画。",
                detail: "",
                howToFill: "开或关即可。",
                examples: ["true"],
                tip: "在同一个父键下的 `targets` 里填要动画的 CSS 选择器，用 `-` 开头的行表示列表项，别写成一行一逗号。"
            )
        ],
        "fireworks": [
            "enable": ConfigDoc(
                summary: "是否在特定页面放烟花特效。",
                detail: "",
                howToFill: "开或关即可。",
                examples: ["true"]
            )
        ],

        // ---- busuanzi：不蒜子统计 ----
        "busuanzi": [
            "enable": ConfigDoc(
                summary: "是否显示访问量统计。",
                detail: "基于第三方服务统计站点和文章的浏览量。",
                howToFill: "开或关即可。",
                examples: ["true"],
                tip: "统计服务在境外时，国内访客经常加载不出来或很慢。对速度敏感就别开。"
            )
        ],

        // ---- sidebar：侧边栏 ----
        "sidebar": [
            "position": ConfigDoc(
                summary: "侧边栏显示在左边还是右边。",
                detail: "",
                howToFill: "left 或 right。",
                examples: ["left"],
                options: [
                    .init(value: "left", label: "left — 靠左（西文站常见）"),
                    .init(value: "right", label: "right — 靠右（中文站更常见）")
                ]
            ),
            "order": ConfigDoc(
                summary: "侧边栏各区块的排列顺序。",
                detail: "数字越小越靠上。里面每一项对应一个区块名。",
                howToFill: "整数列表。区块名写错了这一项会被忽略。",
                examples: ["- 1", "  - 2"]
            ),
            "background": ConfigDoc(
                summary: "侧边栏背景图的深浅色版本。",
                detail: "分别对应亮色和暗色模式。",
                howToFill: "站内图片写 `/images/` 开头，或填完整 https 网址。",
                examples: ["/images/sidebar.jpg"]
            )
        ],

        // ---- avatar：头像 ----
        "avatar": [
            "url": ConfigDoc(
                summary: "头像图片地址。",
                detail: "支持站内路径、外链网址，或者留空改用 Gravatar 邮箱。",
                howToFill: "站内图片写 `/images/avatar.png`；留空则用下面的 `gravatar` 邮箱。",
                examples: ["/images/avatar.png", "https://cdn.example.com/me.jpg"]
            ),
            "gravatar": ConfigDoc(
                summary: "Gravatar 邮箱（由邮箱哈希生成头像）。",
                detail: "填注册过 Gravatar 的邮箱，主题会自动取头像。头像区域用完整网址时这一项会被忽略。",
                howToFill: "完整的邮箱地址，例如 you@example.com。",
                examples: ["you@example.com"]
            ),
            "rounded": ConfigDoc(
                summary: "头像是否显示为圆形。",
                detail: "",
                howToFill: "开或关即可。",
                examples: ["true"]
            ),
            "rotated": ConfigDoc(
                summary: "头像是否跟随鼠标轻微转动。",
                detail: "一个小装饰效果。",
                howToFill: "开或关即可。",
                examples: ["true"]
            )
        ],

        // ---- menu / pages 里的列表项 ----
        "menu": [
            "name": ConfigDoc(
                summary: "导航项显示的文字。",
                detail: "",
                howToFill: "直接写文字，不用加引号。",
                examples: ["首页", "归档"]
            ),
            "link": ConfigDoc(
                summary: "点击导航项跳转到的地址。",
                detail: "站内页面写 `/archives/` 这样的根路径；站外链接写完整 https 网址。",
                howToFill: "站内以 / 开头；站外以 https:// 开头。",
                examples: ["/archives/", "https://github.com/yourname"]
            ),
            "icon": ConfigDoc(
                summary: "导航项前面的图标。",
                detail: "主题用 Iconify 图标库，填的是图标名而不是图片。",
                howToFill: "格式 `图标库:图标名`，例如 `ri:home-line`。图标库可用 ri、bi、fa 等。",
                examples: ["ri:home-line", "bi:folder"],
                tip: "写错的图标名不会报错，只会显示成一个空白方块——这是图标不显示最常见的原因。"
            )
        ],

        // ---- iconify ----
        "iconify": [
            "global": ConfigDoc(
                summary: "是否全局加载 Iconify 图标库。",
                detail: "关掉后只有页面里实际用到的图标才会被加载，能省一些流量。",
                howToFill: "开或关即可。",
                examples: ["true"]
            )
        ]
    ]

    // MARK: 顶层文档

    /// 顶层键的文档。
    static let flat: [String: ConfigDoc] = [

        "language": ConfigDoc(
            summary: "站点界面语言。",
            detail: "主题用它决定导航、日期、按钮这些界面文案显示成什么语言。**只影响界面**，不影响你文章里写的中文。",
            howToFill: "从下拉里选。`zh` 和 `zh-CN` 在多数主题下等价，选哪个都行。",
            examples: ["zh-CN", "en"],
            options: [
                .init(value: "zh-CN", label: "zh-CN — 简体中文"),
                .init(value: "zh", label: "zh — 简体中文（部分主题用这个）"),
                .init(value: "zh-TW", label: "zh-TW — 繁體中文"),
                .init(value: "en", label: "en — 英文"),
                .init(value: "ja", label: "ja — 日本語"),
                .init(value: "ko", label: "ko — 한국어"),
                .init(value: "ru", label: "ru — Русский")
            ],
            tip: "如果下了这个值界面还是英文，多半是当前主题只做了中文和英文两套翻译，切换成 zh 不一定有中文界面。"
        ),

        "url": ConfigDoc(
            summary: "站点对外的完整网址。",
            detail: "**最该先填对的一个键。** 社交链接、文章末尾的版权链接、RSS、站点地图全都靠它拼出来。填错会导致站点上所有绝对链接指向别的域名。",
            howToFill: "协议 + 域名，结尾斜杠可省。不要填 localhost，不要带 /archives/ 这种页面路径。",
            examples: ["https://example.com", "https://blog.example.com"],
            tip: "本地预览时不用管这个；等真正部署到域名上再来填。部署到子目录（如 example.com/blog）时，还要在下面加一行 `root: /blog`。"
        ),

        "permalink": ConfigDoc(
            summary: "文章网址的生成规则。",
            detail: """
            决定每篇文章的 URL 长什么样。常见几种：

            :year/:month/:day/:title/ — 按日期分目录，可读性好，最常用。
            :title/ — 只用标题，最简洁。
            :year/:month/:title/ — 折中。
            """,
            howToFill: "整行替换，保留开头的冒号。",
            examples: [":year/:month/:day/:title/"],
            tip: "⚠️ 改这个会让**所有已发布文章的旧链接失效**，搜索引擎权重也会丢。站已经开张之后不要改。写错格式（比如漏了结尾斜杠）会让 Hexo 构建直接失败。"
        ),

        "timezone": ConfigDoc(
            summary: "时区。",
            detail: "影响文章日期的显示和「今天」这类相对时间的判断。填错会导致文章显示的时间差几个小时。",
            howToFill: "用 IANA 时区名，例如 Asia/Shanghai。",
            examples: ["Asia/Shanghai"],
            options: [
                .init(value: "Asia/Shanghai", label: "Asia/Shanghai — 中国标准时间（UTC+8）"),
                .init(value: "Asia/Hong_Kong", label: "Asia/Hong_Kong — 香港"),
                .init(value: "Asia/Taipei", label: "Asia/Taipei — 台北"),
                .init(value: "Asia/Tokyo", label: "Asia/Tokyo — 东京"),
                .init(value: "Asia/Singapore", label: "Asia/Singapore — 新加坡"),
                .init(value: "Europe/London", label: "Europe/London — 伦敦"),
                .init(value: "America/New_York", label: "America/New_York — 纽约"),
                .init(value: "America/Los_Angeles", label: "America/Los_Angeles — 洛杉矶"),
                .init(value: "UTC", label: "UTC — 协调世界时")
            ]
        ),

        "theme": ConfigDoc(
            summary: "当前使用的主题包名。",
            detail: "填的是 npm 包名（通常带 `hexo-theme-` 前缀），不是主题的中文名。",
            howToFill: "例：landscape、yun。装新主题请到「站点管理 → 主题」页操作，不要手改这里。",
            examples: ["yun", "landscape"]
        ),

        "per_page": ConfigDoc(
            summary: "每页显示几篇文章。",
            detail: "影响首页、归档页、分类页、标签页的分页。",
            howToFill: "正整数。填 0 表示不分页（一次性列出全部文章）。",
            examples: ["10"],
            tip: "文章少的时候 0（不分页）反而更清爽：不用点「下一页」，也不会出现只有一个条目的尴尬页码。"
        ),

        "index_generator": ConfigDoc(
            summary: "首页生成设置。",
            detail: "控制首页显示哪些文章、怎么排序。",
            howToFill: "多数情况下不需要动，保持主题默认值即可。",
            tip: "想让首页只显示摘要、不显示全文，要改 `theme` 下面的 `home_post_content`（展开这个分组才能看到子项）。"
        ),

        "updated_option": ConfigDoc(
            summary: "「更新时间」取哪个时间。",
            detail: "",
            howToFill: "三选一。",
            examples: ["mtime"],
            options: [
                .init(value: "mtime", label: "mtime — 文件的修改时间（改一次文件就变一次）"),
                .init(value: "date", label: "date — 文章 front-matter 里写的 date（发文后永不改变）"),
                .init(value: "empty", label: "empty — 不显示更新时间")
            ]
        ),

        "syntax_highlighter": ConfigDoc(
            summary: "代码高亮引擎。",
            detail: "决定文章里的代码块用什么库着色。",
            howToFill: "二选一。",
            options: [
                .init(value: "prismjs", label: "prismjs — Prism.js（速度快，主题大多为它适配，推荐）"),
                .init(value: "highlighter", label: "highlighter — highlight.js（兼容性老一些）")
            ],
            tip: "选了哪个引擎，下面 `prismjs:` 分组里的设置才会生效；反过来也一样。"
        ),

        "filename_case": ConfigDoc(
            summary: "自动生成的文件名要不要转大小写。",
            detail: "",
            howToFill: "0 不转换 / 1 转小写 / 2 转大写。",
            examples: ["0"],
            options: [
                .init(value: "0", label: "0 — 不转换（保留你输入的样子）"),
                .init(value: "1", label: "1 — 全部转小写"),
                .init(value: "2", label: "2 — 全部转大写")
            ]
        ),

        "root": ConfigDoc(
            summary: "站点部署在子目录时用的根路径。",
            detail: "只有当站点不在域名根目录、而在 `example.com/blog/` 这种子路径下时才需要填。",
            howToFill: "以 / 开头、结尾不带斜杠。主域名部署（example.com/）**留空即可**。",
            examples: ["/blog"],
            tip: "这一项填错的表现是：首页能开，但点任何内页都是 404。GitHub Pages 项目站点必须填。"
        )
    ]

    // MARK: 查表

    /// 按「父键 + 子键」查嵌套文档。
    static func nestedDoc(parent: String, child: String) -> ConfigDoc? {
        nested[parent]?[child]
    }

    /// 按顶层键名查文档。
    static func flatDoc(_ key: String) -> ConfigDoc? {
        flat[key]
    }

    // MARK: 兜底：按值的形状给格式说明

    /// 没有收录的键，至少告诉用户**这个框该填什么形状**。
    ///
    /// 这是「看不懂说明」和「至少知道格式」之间的差别：
    /// 一个没解释过的高亮色 `#0F0F0F`，用户根本不知道它要长什么样。
    static func genericDoc(for kind: ConfigField.Kind, value: String?) -> ConfigDoc? {
        switch kind {
        case .color:
            return ConfigDoc(
                summary: "颜色值。",
                howToFill: "填十六进制色值，井号开头，共 6 位（RGB）或 8 位（带透明度）。",
                examples: ["#FF6B6B", "#0078E7", "#00000080"],
                options: [
                    .init(value: "#0078E7", label: "#0078E7 — 亮蓝色（yun 主题默认）"),
                    .init(value: "#FF8EB3", label: "#FF8EB3 — 浅粉色"),
                    .init(value: "black", label: "black — 纯黑"),
                    .init(value: "white", label: "white — 纯白")
                ],
                tip: "三个十六进制数分别是红、绿、蓝。填 `red` 或 `dodgerblue` 这种英文色名也合法，但记得用英文引号包起来。"
            )
        case .url:
            return ConfigDoc(
                summary: "网址。",
                detail: "以 http:// 或 https:// 开头的完整地址。",
                howToFill: "站内地址通常写 `/archives/` 这样的根路径；站外地址写完整 https 网址。",
                examples: ["https://github.com/yourname", "/archives/"],
                tip: "以 // 开头的地址（协议相对）几乎所有主题都不支持，会变成坏链接。"
            )
        case .asset:
            return ConfigDoc(
                summary: "图片文件地址。",
                detail: "图片要放在站点的 `source/images/` 目录下，配置里写 `/images/文件名` 引用它。",
                howToFill: "站内：/images/xxx.png；站外：完整 https 网址。",
                examples: ["/images/avatar.png", "https://cdn.example.com/a.jpg"],
                tip: "写文件名而不带 `/images/` 前缀是最常见的图片不显示原因。中文文件名和空格也容易出问题，建议全用英文小写加连字符。"
            )
        case .boolean:
            return ConfigDoc(
                summary: "开或关。",
                howToFill: "开关直接点，不需要手填文字。",
                examples: ["true", "false"]
            )
        case .integer:
            return ConfigDoc(
                summary: "一个整数。",
                howToFill: "只填数字，不要加单位。",
                examples: ["10", "0"],
                tip: value.map { "当前是 \($0)。不确定含义时先别改，填错数字一般不会报错，但页面可能显示异常。" }
            )
        case .multiline:
            return ConfigDoc(
                summary: "多行文本。",
                detail: "每一行是一个条目，不需要写 `-` 之类的列表符号。",
                howToFill: "一行一个值。留空表示不设置。",
                examples: ["node_modules", "public"],
                tip: "在 YAML 里给多行文本续行时，行尾的 `|` 不能漏——少了它后面几行会被当成新的顶层键，直接把配置文件改坏。"
            )
        case .text:
            guard let value, !value.isEmpty else { return nil }
            return ConfigDoc(
                summary: "文本。",
                howToFill: "直接填写，一般不需要引号。",
                examples: [value],
                tip: "含 `:` `#` `[` `]` 等 YAML 特殊符号时需要加英文引号。留空表示不设置。"
            )
        case .choice(let options):
            guard !options.isEmpty else { return nil }
            return ConfigDoc(summary: "从下拉里选一个。", options: options)
        case .readOnly:
            return nil
        }
    }
}