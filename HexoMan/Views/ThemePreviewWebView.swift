//
//  ThemePreviewWebView.swift
//  HexoMan
//
//  主题官方 demo 的内嵌预览。WKWebView 包装成 SwiftUI 视图。
//
//  已知坑：部分主题（如 next）官方 demo 站带 X-Frame-Options: SAMEORIGIN，
//  WKWebView 里会渲染成空白（不报错）。这种情况 UI 层会同时显示
//  「在浏览器中打开」链接作为降级方案。
//

import SwiftUI
import WebKit

struct ThemePreviewWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // 沙盒之外是默认配置；HexoMan 没开沙盒（ENABLE_APP_SANDBOX: "NO"），
        // 所以 WKWebView 不需要额外的 entitlement。

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // 不让 WKWebView 推挤外层布局——关掉滚动视图的内容大小自动调整，
        // 配合外面 `.frame(height:)` 把高度锁死，HSplitView 不会被 WebView 推着抖。
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width]
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // URL 在 view 生命周期内不变；URL 变就是重建 view（HexoMan 没这场景）。
        // 不在这里重新 load——会盖掉用户滚动位置。
    }

    /// 给外面 SwiftUI 用的「期望高度」——避免被 SwiftUI 算出奇怪值。
    static let preferredHeight: CGFloat = 260

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        // 不拦截任何导航——用户点了内嵌预览里的链接，按 WebView 默认行为在新窗口打开。
        // 拦截会引入不必要的复杂度，且主题官方 demo 通常不会有恶意跳转。
    }
}