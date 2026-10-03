//
//  SnippetLibrary.swift
//  HexoMan
//
//  预置的常用代码片段。
//
//  定位很明确：小白不是不会写 HTML/CSS/JS，是不知道「加在哪个位置、填什么」。
//  这里把最高频的几件事做成一键插入，省掉搜索和试错。
//
//  每条都标注了推荐插入的位置（head / body），因为放错位置是最常见的失败原因：
//  CSS 放 body 里要等页面闪一下才生效，统计脚本放 head 里又会拖慢首屏。
//

import Foundation

/// 一段可一键插入的代码。
struct Snippet: Identifiable {

    enum Target: String, CaseIterable, Identifiable {
        case head = "head"
        case body = "body"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .head: return "</head> 前"
            case .body: return "</body> 前"
            }
        }
    }

    var id: String
    var title: String
    /// 这个片段解决什么问题
    var summary: String
    var target: Target
    var code: String
    /// 需要用户先填的东西。空数组表示可以原样插入。
    var placeholders: [Placeholder] = []

    /// 代码里需要用户替换的部分。
    struct Placeholder: Identifiable {
        var id: String
        var title: String
        var hint: String
        /// 代码里的占位标记，写入时会被替换掉
        var token: String
    }
}

/// 片段库。
enum SnippetLibrary {

    static let all: [Snippet] = [
        Snippet(
            id: "keepandroidopen",
            title: "友情链接挂件（keepandroidopen）",
            summary: "在页面右下角挂一个可滚动的友情链接卡片，占位很小。插入后请到对方网站注册你的站点。",
            target: .body,
            code: "<script src=\"https://keepandroidopen.org/banner.js\"></script>"
        ),
        Snippet(
            id: "custom-css",
            title: "自定义 CSS",
            summary: "改主题样式。改这里而不是改主题源码——改源码会在 npm install 时丢失。",
            target: .head,
            code: """
            <style>
            /* 例：把正文行宽收窄一点，长文更好读 */
            .post-body {
              max-width: 42em;
              margin-left: auto;
              margin-right: auto;
            }
            </style>
            """
        ),
        Snippet(
            id: "custom-js",
            title: "自定义 JS",
            summary: "在每个页面执行自己的脚本。适合做小挂件、埋点、快捷键。",
            target: .body,
            code: "<script>\n/* 在这里写你的代码 */\n</script>"
        ),
        Snippet(
            id: "umami",
            title: "访问统计（Umami）",
            summary: "自托管的访问统计，不依赖第三方。加在 head 里，首屏统计更准。",
            target: .head,
            code: "<script defer src=\"https://cloud.umami.is/script.js\" data-website-id=\"__UMAMI_WEBSITE_ID__\"></script>",
            placeholders: [
                .init(id: "website", title: "Website ID", hint: "Umami 后台设置页里的 Website ID，形如 a1b2c3d4-...", token: "__UMAMI_WEBSITE_ID__")
            ]
        ),
        Snippet(
            id: "google-analytics",
            title: "访问统计（Google Analytics）",
            summary: "填入你的 GA4 衡量 ID（G- 开头的长字符串）。",
            target: .head,
            code: """
            <!-- Google tag (gtag.js) -->
            <script async src="https://www.googletagmanager.com/gtag/js?id=__GA_ID__"></script>
            <script>
              window.dataLayer = window.dataLayer || [];
              function gtag(){dataLayer.push(arguments);}
              gtag('js', new Date());
              gtag('config', '__GA_ID__');
            </script>
            """,
            placeholders: [
                .init(id: "ga", title: "衡量 ID", hint: "GA4 后台的「衡量 ID」，形如 G-XXXXXXXXXX", token: "__GA_ID__")
            ]
        ),
        Snippet(
            id: "baidu-tongji",
            title: "访问统计（百度统计）",
            summary: "国内访问更快。插入后需要到百度统计后台绑定域名。",
            target: .head,
            code: """
            <script>
            var _hmt = _hmt || [];
            (function () {
              var hm = document.createElement("script");
              hm.src = "https://hm.baidu.com/hm.js?__BAIDU_ID__";
              document.getElementsByTagName("head")[0].appendChild(hm);
            })();
            </script>
            """,
            placeholders: [
                .init(id: "hm", title: "统计 ID", hint: "百度统计后台统计代码里 hm.baidu.com 后面那串数字", token: "__BAIDU_ID__")
            ]
        ),
        Snippet(
            id: "fontawesome",
            title: "图标字体（Font Awesome）",
            summary: "装上之后在文章里用 <i class=\"fa-solid fa-xxx\"> 就能显示图标。",
            target: .head,
            code: "<link rel=\"stylesheet\" href=\"https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css\">"
        ),
        Snippet(
            id: "icp",
            title: "备案号",
            summary: "国内服务器通常要求在页脚显示备案号。放在 body 里，具体位置取决于主题。",
            target: .body,
            code: """
            <div style="text-align:center;font-size:13px;color:#888;padding:20px 0;">
              <a href="https://beian.miit.gov.cn/" target="_blank" rel="noopener" style="color:#888;text-decoration:none;">__ICP__</a>
            </div>
            """,
            placeholders: [
                .init(id: "icp", title: "备案号", hint: "形如 京ICP备00000000号-1", token: "__ICP__")
            ]
        ),
        Snippet(
            id: "noindex",
            title: "阻止搜索引擎收录",
            summary: "给整站加 noindex。只在你不想被收录时用（比如还在写、或者只是自用）。",
            target: .head,
            code: "<meta name=\"robots\" content=\"noindex, nofollow\">"
        ),
        Snippet(
            id: "verify-meta",
            title: "搜索引擎站长验证",
            summary: "验证所有权用的 meta 标签。Google 站长平台的「HTML 标记」方式就填这里。",
            target: .head,
            code: "<meta name=\"google-site-verification\" content=\"__VERIFY__\">",
            placeholders: [
                .init(id: "content", title: "content 值", hint: "站长平台给你的一长串字符", token: "__VERIFY__")
            ]
        )
    ]

    static func snippets(for target: Snippet.Target) -> [Snippet] {
        all.filter { $0.target == target }
    }

    /// 把占位标记替换成用户填的值。没填的占位会原样留着并提醒。
    static func instantiate(_ snippet: Snippet, values: [String: String]) -> (code: String, missing: [String]) {
        var code = snippet.code
        var missing: [String] = []

        for placeholder in snippet.placeholders {
            if let value = values[placeholder.id], value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                code = code.replacingOccurrences(of: placeholder.token, with: value)
            } else {
                missing.append(placeholder.title)
            }
        }

        return (code, missing)
    }
}
