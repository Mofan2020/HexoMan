//
//  CustomContent.swift
//  HexoMan
//
//  「我想加个 banner / 统计代码 / 自定义 CSS，该往哪填？」
//
//  这是小白卡住频率最高的问题，答案对绝大多数用户都是「不知道」。
//  常见误区是去 themes/landscape/layout/ 里改模板——那在 npm install 时会被直接覆盖，
//  升级主题就白改一次。
//
//  这里的做法是自动在站点里生成一对文件：
//
//    <站点>/scripts/hexoman-inject.json   ← 你填的 HTML，HexoMan 管理
//    <站点>/scripts/hexoman-inject.js     ← 注入逻辑，HexoMan 管理
//
//  生成的脚本走 Hexo 的 `_after_html_render` 钩子（**不是** `after_generate`——
//  Hexo 8 里那个钩子的 data 是 null，拿不到 HTML 字符串），
//  在每页的 `</head>` / `</body>` 前插入内容。
//
//  放在 scripts/ 目录而不是主题源码里，有三个好处：
//  - 升级主题、重新 npm install 都不会丢
//  - 不依赖主题支不支持某个注入目录，换任何主题都通用
//  - 删掉这两个文件就等于彻底关掉这个功能，没有任何残留
//

import Foundation

/// 用户想在每页插入的自定义内容。
struct CustomContent: Equatable {
    /// 插在 `</head>` 之前。放 CSS、统计脚本、字体。
    var head: String = ""
    /// 插在 `</body>` 之前。放 banner 挂件、悬浮按钮。
    var body: String = ""

    var isEmpty: Bool {
        head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 读写注入配置与脚本。
enum CustomContentStore {

    /// 数据文件名。
    static let dataFileName = "hexoman-inject.json"
    /// 脚本文件名。
    static let scriptFileName = "hexoman-inject.js"

    static func dataPath(site: HexoSite) -> String {
        (site.path as NSString)
            .appendingPathComponent("scripts/\(dataFileName)")
    }

    static func scriptPath(site: HexoSite) -> String {
        (site.path as NSString)
            .appendingPathComponent("scripts/\(scriptFileName)")
    }

    /// 站点是否已经启用了注入。
    static func isInstalled(site: HexoSite) -> Bool {
        FileManager.default.fileExists(atPath: dataPath(site: site))
            || FileManager.default.fileExists(atPath: scriptPath(site: site))
    }

    /// 读回用户填的内容。文件不存在或格式不对都按空处理。
    static func load(site: HexoSite) -> CustomContent {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath(site: site))),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return CustomContent() }

        return CustomContent(
            head: object["head"] as? String ?? "",
            body: object["body"] as? String ?? ""
        )
    }

    /// 保存内容。
    ///
    /// 顺带把脚本文件一起写上——用户不该需要点两次才生效。
    /// 传 `installScript: false` 可以只存数据不动脚本（给「脚本被手工改过」的场合用）。
    static func save(_ content: CustomContent, site: HexoSite) throws {
        let directory = (site.path as NSString).appendingPathComponent("scripts")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // 带 BOM 的 JSON 在某些 Node 版本上会解析失败，所以显式用不带 BOM 的 UTF-8。
        let payload: [String: String] = [
            "head": content.head,
            "body": content.body
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: dataPath(site: site)), options: .atomic)

        if FileManager.default.fileExists(atPath: scriptPath(site: site)) == false {
            try scriptTemplate.write(to: URL(fileURLWithPath: scriptPath(site: site)), atomically: true, encoding: .utf8)
        }
    }

    /// 关掉注入：删掉这两个文件。站点回到「完全没动过」的状态。
    static func remove(site: HexoSite) throws {
        for path in [dataPath(site: site), scriptPath(site: site)] {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// 注入脚本模板。
    ///
    /// 写成纯 CommonJS、不引任何依赖，是为了在 Hexo 6/7/8 上都能跑。
    /// 刻意不硬编码用户填的内容——内容放 JSON，脚本只管读，
    /// 这样用户想手动微调 HTML 时也不需要碰 JS。
    ///
    /// **兼容两种入参形态是这里最重要的一件事。**
    /// `_after_html_render` 在不同 Hexo 版本里传的东西不一样：
    /// Hexo 8.1.2 实测传的是**字符串**，而传 `{ path, content }` 对象的版本也存在。
    /// 早期版本这里写死 `data.content`，在 8.1.2 上会让 filter 返回 `undefined`——
    /// 后果不是「没注入」，而是**整站 HTML 被渲染成 0 字节**。
    /// 所以这里先归一化成字符串，并且**任何分支都保证返回值非空**。
    static let scriptTemplate = """
    //
    //  hexoman-inject.js
    //  由 HexoMan 生成
    //
    //  作用：把 hexoman-inject.json 里填的 HTML 插到每页的 </head> 和 </body> 之前。
    //  想改内容请用 HexoMan 的「配置 → 自定义内容」，或直接编辑同目录的 json。
    //  删掉 hexoman-inject.json 和本文件即可完全关闭这个功能。
    //

    const fs = require('fs');
    const path = require('path');

    const dataFile = path.join(__dirname, 'hexoman-inject.json');

    function loadContent() {
      try {
        return JSON.parse(fs.readFileSync(dataFile, 'utf8')) || {};
      } catch (error) {
        // 文件还没建或者写坏了，都按「不注入」处理，绝不让 hexo build 因此崩掉
        return {};
      }
    }

    // 关键：必须用 _after_html_render。
    // after_generate 在 Hexo 8 里拿到的 data 是 null，没有 HTML 字符串可用。
    hexo.extend.filter.register('_after_html_render', function (data) {
      // 不同 Hexo 版本传的形态不一样，先统一成字符串再处理。
      // 这里绝不能想当然写 data.content —— 在传字符串的版本上那会是 undefined。
      const isObject = data !== null && typeof data === 'object';
      const original = isObject ? (data.content || '') : String(data === undefined || data === null ? '' : data);

      let html = original;
      const content = loadContent();

      if (content.head) {
        html = html.indexOf('</head>') >= 0
          ? html.replace('</head>', content.head + '\\n</head>')
          : content.head + '\\n' + html;
      }

      if (content.body) {
        html = html.indexOf('</body>') >= 0
          ? html.replace('</body>', content.body + '\\n</body>')
          : html + '\\n' + content.body;
      }

      // 兜底：任何情况下都不能返回空。返回空等于把用户整个站点渲染成 0 字节。
      if (!html) {
        return data;
      }

      return isObject ? Object.assign({}, data, { content: html }) : html;
    });

    """
}

// MARK: - 识别站点里已有的注入脚本

/// 站点 `scripts/` 目录下一个**会往生成结果里插东西**的脚本。
///
/// 为什么需要识别：
///
/// Hexo 会自动加载站点根目录 `scripts/` 下的所有 js，所以用户（或者教程、AI）
/// 完全可能自己放一个 `banner.js` 之类的注入脚本。这种脚本完全有效，
/// 但 HexoMan 原先只认自己那两个文件名（hexoman-inject.json/.js），
/// 于是会出现**界面说「未启用」、站点上横幅其实天天在显示**的错位——
/// 用户会以为自己配错了，实际上是工具没看见。
///
/// 识别出来之后至少能：如实告诉用户「你已经有注入脚本了」，
/// 指出它在插什么、插到哪，避免再配一份导致同一段内容出现两次。
struct DetectedInjectScript: Identifiable {

    var id: String { path }

    /// 绝对路径
    var path: String
    /// 文件名
    var fileName: String
    /// 注册的 Hexo 钩子名，例如 `_after_html_render`
    var hooks: [String]
    /// 插入的位置，例如 `</body>`
    var insertsInto: [String]
    /// 脚本里引用的外部资源（src/href），用来告诉用户「它加载的是什么东西」
    var externalSources: [String]
    /// 是否是 HexoMan 自己生成的那个
    var isManagedByHexoMan: Bool

    /// 一句话概括。
    var summary: String {
        if hooks.isEmpty { return "未识别到 Hexo 钩子" }
        var parts = [hooks.joined(separator: ", ")]
        if insertsInto.isEmpty == false {
            parts.append("插入到 \(insertsInto.joined(separator: "、")) 前")
        }
        return parts.joined(separator: " · ")
    }

    /// 外部资源的展示名。
    var sourceDescription: String {
        if externalSources.isEmpty { return "没有引用外部资源" }
        return externalSources.joined(separator: "\n")
    }
}

extension CustomContentStore {

    /// 扫描站点的 `scripts/` 目录，找出所有注入脚本（含 HexoMan 自己的）。
    ///
    /// 只认这几种「真的会改生成结果」的形式：
    /// - `hexo.extend.filter.register('<hook>', …)`
    /// - 注册时把内容插到 `</head>` / `</body>` / `</html>` 前面
    ///
    /// 刻意不做完整 JS 解析——站点里的脚本是用户自己写的，
    /// 宁可漏报也不要给出一堆误报把界面搞脏。
    static func detectedInjectScripts(site: HexoSite) -> [DetectedInjectScript] {

        let scriptsDir = URL(fileURLWithPath: (site.path as NSString).appendingPathComponent("scripts"))
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: scriptsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [DetectedInjectScript] = []

        for case let fileURL as URL in enumerator {
            let relative = fileURL.path.replacingOccurrences(of: scriptsDir.path + "/", with: "")
            guard relative.lowercased().hasSuffix(".js") else { continue }

            let fullPath = fileURL.path
            // 太大的文件不扫，免得为了一个 2MB 的库文件去跑一堆正则
            guard let attributes = try? fm.attributesOfItem(atPath: fullPath),
                  let size = attributes[.size] as? Int, size < 512 * 1024,
                  let text = try? String(contentsOfFile: fullPath, encoding: .utf8)
            else { continue }

            let hooks = matches(pattern: "hexo\\.extend\\.filter\\.register\\s*\\(\\s*['\"]([^'\"]+)['\"]", in: text)
            let inserts = ["</head>", "</body>", "</html>"].filter { text.contains($0) }

            // 只有「注册了钩子」或「提到了插入位置」才算是注入脚本。
            // scripts/ 里经常还放着别的工具脚本，不能一律当成注入。
            guard hooks.isEmpty == false || inserts.isEmpty == false else { continue }

            let sources = matches(pattern: "(?:src|href)\\s*=\\s*['\"]([^'\"]+)['\"]", in: text)
                + matches(pattern: "['\"](https?://[^'\"]+?\\.js)['\"]", in: text)

            result.append(DetectedInjectScript(
                path: fullPath,
                fileName: (relative as NSString).lastPathComponent,
                hooks: Array(Set(hooks)).sorted(),
                insertsInto: inserts,
                externalSources: Array(Set(sources)).sorted(),
                isManagedByHexoMan: (relative as NSString).lastPathComponent == scriptFileName
            ))
        }

        return result.sorted { $0.fileName < $1.fileName }
    }

    /// 用正则抓第一个捕获组里所有命中的内容。
    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[capture])
        }
    }
}
