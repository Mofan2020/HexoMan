/*
 * HexoMan — 前端。
 *
 * 结构：状态在 `state`，视图由 `render*` 函数按当前页面重绘。
 * 后端是 `window.hexoman`（pywebview 注入的 JS API）。
 *
 * 两条硬规则：
 *
 * 1. **语言切换不重载页面。** 后端返回新的文案字典后，只重绘文本节点，
 *    状态和滚动位置全部保留。
 * 2. **图标一律用内联 SVG。** 不用 emoji —— emoji 在不同系统上长相不一，
 *    且没法跟随主题着色。
 */

(function () {
  "use strict";

  // ------------------------------------------------------------ 状态

  var state = {
    strings: {},
    language: "zh",
    languages: [],
    sites: [],
    currentSitePath: "",
    siteInfo: null,
    posts: [],
    tags: [],
    categories: [],
    selectedPostPath: "",
    postFilter: "all",
    postSearch: "",
    editorMode: "split", // split | write | read
    serverPort: 4000,
    serverRunning: false,
    platform: "",
    page: "overview",
    log: [],
    dirty: false,
    previewDrafts: false,

    // 页面管理
    pages: [],
    selectedPagePath: "",
    pageBody: "",
    pageFields: [],
    pageAssets: [],
    pageReferences: [],
    pageDirty: false,

    // 配置
    configFiles: [],
    configPath: "",
    configFields: [],
    configRaw: "",
    configTab: "fields",
    configSync: null,

    // 主题
    themes: [],
    activeTheme: "",
    themeResults: [],
    themeQuery: "",

    // 备份
    backups: [],
    backupPlan: null,

    // 环境
    toolchain: null,
    envSections: [],

    // 构建
    buildOutput: "",
    buildRunning: false,

    // Git
    gitStatus: null,
    commits: [],
    gitMessage: "",
    gitOutput: "",
  };

  // 编辑器三种模式的文案 key。分开写是因为 ``split`` 这个词在文案里
  // 叫「分栏」，直接拼 ``posts.split`` 会查不到。
  var EDITOR_MODE_KEYS = {
    write: "posts.write",
    split: "posts.splitView",
    read: "posts.read",
  };

  var NAV_ITEMS = [
    {
      group: "nav.group.site",
      items: [
        { id: "sites", label: "nav.sites", icon: "folder" },
        { id: "overview", label: "nav.overview", icon: "gauge" },
      ],
    },
    {
      group: "nav.group.content",
      items: [
        { id: "posts", label: "nav.posts", icon: "document" },
        { id: "pages", label: "nav.pages", icon: "documents" },
      ],
    },
    {
      group: "nav.group.tool",
      items: [
        { id: "build", label: "nav.build", icon: "hammer" },
        { id: "config", label: "nav.config", icon: "sliders" },
        { id: "theme", label: "nav.theme", icon: "palette" },
        { id: "git", label: "nav.git", icon: "branch" },
        { id: "backup", label: "nav.backup", icon: "archive" },
        { id: "environment", label: "nav.environment", icon: "terminal" },
      ],
    },
  ];

  // ------------------------------------------------------------ 图标

  var ICONS = {
    folder:
      '<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h4.2l1.6 2h9.2A1.5 1.5 0 0 1 21 9.5v8A1.5 1.5 0 0 1 19.5 19h-15A1.5 1.5 0 0 1 3 17.5z"/>',
    gauge:
      '<path d="M12 14a2 2 0 1 0 0-4 2 2 0 0 0 0 4z"/><path d="m13.4 10.6 3.9-2.2"/><path d="M4.2 18a9 9 0 1 1 15.6 0"/>',
    document:
      '<path d="M6 3.5h7.5L18 8v12.5H6z"/><path d="M13 3.5V8h5"/><path d="M9 12h6M9 15.5h6"/>',
    documents:
      '<path d="M8 3.5h7.5L19 8v9.5H8z"/><path d="M14 3.5V8h5"/><path d="M5 7v13.5h9"/>',
    hammer:
      '<path d="m14 5 5 5"/><path d="M12.2 6.8 6 13l-2.6-.9L4 10l8.2-6.2z"/><path d="m3.6 14.4 4.4 2.5"/>',
    sliders:
      '<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
    palette:
      '<path d="M12 3a9 9 0 0 0 0 18c1.1 0 1.8-.8 1.8-1.7 0-.5-.2-.9-.5-1.2-.3-.3-.5-.7-.5-1.1 0-.9.8-1.7 1.7-1.7H16A5 5 0 0 0 21 10c0-3.9-4-7-9-7z"/><circle cx="7.5" cy="11" r="1"/><circle cx="10" cy="7.5" r="1"/><circle cx="15" cy="8" r="1"/>',
    branch:
      '<circle cx="6.5" cy="6" r="2.4"/><circle cx="6.5" cy="18" r="2.4"/><circle cx="17.5" cy="9.5" r="2.4"/><path d="M6.5 8.4v7.2"/><path d="M17.5 11.9c0 2.7-2.4 3.6-5.2 4.1"/>',
    archive:
      '<rect x="3.5" y="4.5" width="17" height="4.5" rx="1.2"/><path d="M5.2 9v9.2A1.8 1.8 0 0 0 7 20h10a1.8 1.8 0 0 0 1.8-1.8V9"/><path d="M10 13h4"/>',
    terminal:
      '<rect x="3" y="4.5" width="18" height="15" rx="2"/><path d="m7.5 10 2.5 2.5-2.5 2.5"/><path d="M12.5 15.5h4"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    trash:
      '<path d="M4.5 7h15"/><path d="M9.5 7V5.2A1.2 1.2 0 0 1 10.7 4h2.6a1.2 1.2 0 0 1 1.2 1.2V7"/><path d="M6.5 7 7.4 19a1.6 1.6 0 0 0 1.6 1.5h6a1.6 1.6 0 0 0 1.6-1.5L17.5 7"/>',
    refresh:
      '<path d="M20 11a8 8 0 1 0-1.4 5.4"/><path d="M20 5v6h-6"/>',
    play: '<path d="M8 5.5 18.5 12 8 18.5z"/>',
    stop: '<rect x="6.5" y="6.5" width="11" height="11" rx="1.5"/>',
    globe:
      '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17"/><path d="M12 3.5c2.2 2.4 3.3 5.3 3.3 8.5S14.2 18.1 12 20.5c-2.2-2.4-3.3-5.3-3.3-8.5S9.8 5.9 12 3.5z"/>',
    eye:
      '<path d="M2.5 12S6 5.8 12 5.8 21.5 12 21.5 12 18 18.2 12 18.2 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="2.8"/>',
    save:
      '<path d="M5 4.5h11L19.5 8v11.5H5z"/><path d="M8.5 4.5v5h7v-5"/><rect x="8.5" y="13" width="7" height="6.5"/>',
    pencil:
      '<path d="M4.5 19.5h4L19 9a2.1 2.1 0 0 0-3-3L5.5 16.5z"/><path d="m14.5 6.5 3 3"/>',
    info:
      '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5"/><circle cx="12" cy="7.8" r=".9" fill="currentColor" stroke="none"/>',
    warn:
      '<path d="M10.6 4.2 3.3 17a1.6 1.6 0 0 0 1.4 2.4h14.6a1.6 1.6 0 0 0 1.4-2.4L13.4 4.2a1.6 1.6 0 0 0-2.8 0z"/><path d="M12 9.5v4"/><circle cx="12" cy="16.3" r=".9" fill="currentColor" stroke="none"/>',
    check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
    package:
      '<path d="M12 3.5 20 8v8l-8 4.5L4 16V8z"/><path d="M4 8l8 4.5L20 8"/><path d="M12 12.5V21"/>',
    cog:
      '<circle cx="12" cy="12" r="3"/><path d="M12 3v2.2M12 18.8V21M3 12h2.2M18.8 12H21M5.6 5.6l1.6 1.6M16.8 16.8l1.6 1.6M18.4 5.6l-1.6 1.6M7.2 16.8l-1.6 1.6"/>',
    box: '<path d="M3.5 8 12 3.5 20.5 8v8L12 20.5 3.5 16z"/><path d="M3.5 8 12 12.5 20.5 8"/><path d="M12 12.5v8"/>',
    clock:
      '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
    tag: '<path d="M3.8 11.4 11.4 3.8H20v8.6l-7.6 7.6z"/><circle cx="16.2" cy="7.8" r="1.3"/>',
    file:
      '<path d="M6 3.5h7.5L18 8v12.5H6z"/><path d="M13 3.5V8h5"/>',
  };

  function icon(name, size) {
    var body = ICONS[name] || ICONS.info;
    var px = size || 16;
    return (
      '<svg viewBox="0 0 24 24" width="' +
      px +
      '" height="' +
      px +
      '" fill="none" stroke="currentColor" stroke-width="1.7" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      body +
      "</svg>"
    );
  }

  // ------------------------------------------------------------ 工具

  function t(key, fallback) {
    var value = state.strings[key];
    if (value === undefined || value === null || value === "") {
      return fallback !== undefined ? fallback : key;
    }
    return value;
  }

  /** 把文案里的 `{name}` 占位符替换掉。 */
  function tf(key, vars, fallback) {
    var text = t(key, fallback);
    Object.keys(vars || {}).forEach(function (name) {
      text = text.split("{" + name + "}").join(vars[name]);
    });
    return text;
  }

  function el(id) {
    return document.getElementById(id);
  }

  function escapeHtml(text) {
    return String(text === undefined || text === null ? "" : text).replace(
      /[&<>"']/g,
      function (char) {
        return {
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#39;",
        }[char];
      }
    );
  }

  function formatBytes(bytes) {
    if (!bytes && bytes !== 0) return "";
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
    return (bytes / 1024 / 1024).toFixed(1) + " MB";
  }

  function formatTimestamp(seconds) {
    if (!seconds) return "";
    var date = new Date(seconds * 1000);
    if (isNaN(date.getTime())) return "";
    function pad(value) {
      return value < 10 ? "0" + value : String(value);
    }
    return (
      date.getFullYear() +
      "-" +
      pad(date.getMonth() + 1) +
      "-" +
      pad(date.getDate()) +
      " " +
      pad(date.getHours()) +
      ":" +
      pad(date.getMinutes())
    );
  }

  /** 当前站点的对象；没有选中站点时返回 null。 */
  function currentSite() {
    for (var i = 0; i < state.sites.length; i++) {
      if (state.sites[i].path === state.currentSitePath) return state.sites[i];
    }
    return null;
  }

  function hasSite() {
    return !!currentSite();
  }

  // ------------------------------------------------------------ 后端调用

  /** 调后端方法；后端没挂上时返回 null（纯浏览器预览场景）。 */
  function api(method) {
    var args = Array.prototype.slice.call(arguments, 1);
    if (!window.hexoman || typeof window.hexoman[method] !== "function") {
      return Promise.resolve(null);
    }
    try {
      return Promise.resolve(window.hexoman[method].apply(window.hexoman, args));
    } catch (error) {
      console.error("调用后端方法失败：" + method, error);
      return Promise.resolve(null);
    }
  }

  // ------------------------------------------------------------ 提示条

  function toast(message, kind) {
    var host = el("toast-host");
    if (!host) return;
    var node = document.createElement("div");
    node.className = "toast " + (kind === "error" ? "is-error" : "is-success");
    node.textContent = message;
    host.appendChild(node);
    setTimeout(function () {
      if (node.parentNode) node.parentNode.removeChild(node);
    }, 3200);
  }

  // ------------------------------------------------------------ 弹层

  function openModal(options) {
    var backdrop = document.createElement("div");
    backdrop.className = "modal-backdrop";

    var modal = document.createElement("div");
    modal.className = "modal";
    modal.innerHTML =
      '<h2 class="modal-title"></h2>' +
      '<div class="modal-body"></div>' +
      '<div class="modal-form"></div>' +
      '<div class="modal-actions"></div>';

    modal.querySelector(".modal-title").textContent = options.title || "";
    modal.querySelector(".modal-body").textContent = options.body || "";

    var formHost = modal.querySelector(".modal-form");
    var actions = modal.querySelector(".modal-actions");
    var inputs = {};

    (options.fields || []).forEach(function (field) {
      var wrapper = document.createElement("label");
      wrapper.className = "field";
      var label = document.createElement("span");
      label.className = "field-label";
      label.textContent = field.label;
      var input = document.createElement("input");
      input.className = "input";
      input.type = "text";
      input.placeholder = field.placeholder || "";
      input.value = field.value || "";
      wrapper.appendChild(label);
      wrapper.appendChild(input);
      formHost.appendChild(wrapper);
      inputs[field.name] = input;
    });

    function close() {
      if (backdrop.parentNode) backdrop.parentNode.removeChild(backdrop);
    }

    (options.actions || []).forEach(function (action) {
      var button = document.createElement("button");
      button.type = "button";
      button.className = "button" + (action.primary ? " is-primary" : "");
      button.textContent = action.label;
      button.addEventListener("click", function () {
        var values = {};
        Object.keys(inputs).forEach(function (name) {
          values[name] = inputs[name].value;
        });
        if (action.onClick && action.onClick(values) === false) return;
        close();
      });
      actions.appendChild(button);
    });

    backdrop.appendChild(modal);
    backdrop.addEventListener("mousedown", function (event) {
      if (event.target === backdrop) close();
    });

    document.body.appendChild(backdrop);
    var firstInput = formHost.querySelector("input");
    if (firstInput) firstInput.focus();

    return { close: close };
  }

  /**
   * 通用的确认 / 表单弹窗。
   *
   * ``openModal`` 的 ``body`` 是按纯文本处理的，也不支持 onMount，够不到
   * 「弹窗里塞几个自定义控件」这种场景。这里补一个：
   * ``html`` 原样插进弹窗，``onMount`` 拿到弹窗节点后自己绑事件。
   */
  function customDialog(options) {
    var backdrop = document.createElement("div");
    backdrop.className = "modal-backdrop";

    var modal = document.createElement("div");
    modal.className = "modal";
    modal.innerHTML =
      '<h2 class="modal-title"></h2>' +
      '<div class="modal-body"></div>' +
      '<div class="modal-actions"></div>';

    modal.querySelector(".modal-title").textContent = options.title || "";
    modal.querySelector(".modal-body").innerHTML = options.html || "";

    var actions = modal.querySelector(".modal-actions");

    function close() {
      if (backdrop.parentNode) backdrop.parentNode.removeChild(backdrop);
    }

    var cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "button";
    cancel.textContent = t("common.cancel");
    cancel.addEventListener("click", close);
    actions.appendChild(cancel);

    var confirm = document.createElement("button");
    confirm.type = "button";
    confirm.className = "button is-primary";
    confirm.textContent = options.confirmLabel || t("common.confirm");
    confirm.addEventListener("click", function () {
      if (options.onConfirm) options.onConfirm(modal);
      close();
    });
    actions.appendChild(confirm);

    backdrop.appendChild(modal);
    backdrop.addEventListener("mousedown", function (event) {
      if (event.target === backdrop) close();
    });
    document.body.appendChild(backdrop);

    if (options.onMount) options.onMount(modal);
    var firstInput = modal.querySelector("input");
    if (firstInput) firstInput.focus();

    return { close: close };
  }

  // ------------------------------------------------------------ 侧边栏

  function renderNav() {
    var nav = el("nav");
    if (!nav) return;
    nav.innerHTML = "";

    NAV_ITEMS.forEach(function (group) {
      var label = document.createElement("div");
      label.className = "nav-group-label";
      label.textContent = t(group.group);
      nav.appendChild(label);

      group.items.forEach(function (item) {
        var button = document.createElement("button");
        button.type = "button";
        button.className = "nav-item" + (state.page === item.id ? " is-active" : "");
        var tag = item.tag === "soon" ? '<span class="nav-item-tag">soon</span>' : "";
        button.innerHTML =
          icon(item.icon) +
          '<span class="nav-item-label"></span>' +
          tag;

        button.querySelector(".nav-item-label").textContent = t(item.label);
        button.addEventListener("click", function () {
          state.page = item.id;
          closeSiteMenu();
          render();
        });
        nav.appendChild(button);
      });
    });
  }

  function renderLanguageToggle() {
    var host = el("lang-toggle");
    if (!host) return;
    host.innerHTML = "";

    state.languages.forEach(function (language) {
      var button = document.createElement("button");
      button.type = "button";
      button.className =
        "lang-button" + (state.language === language.code ? " is-active" : "");
      button.textContent = language.code === "zh" ? "中文" : "EN";
      button.title = language.name;
      button.addEventListener("click", function () {
        if (state.language === language.code) return;
        switchLanguage(language.code);
      });
      host.appendChild(button);
    });
  }

  /**
   * 切换语言。
   *
   * 关键点：**不重新加载页面**。后端返回新字典后只重绘受影响的文本，
   * 当前页面、选中状态、滚动位置全部保留。
   */
  function switchLanguage(code) {
    api("setLanguage", code).then(function (result) {
      if (!result || !result.ok) {
        toast(t("common.error"), "error");
        return;
      }
      state.language = result.language;
      state.strings = result.strings || {};
      render();
      toast(t("common.saved"));
    });
  }

  function renderSiteSwitcher() {
    var name = el("current-site-name");
    var path = el("current-site-path");
    var site = currentSite();

    if (!site) {
      name.textContent = t("sites.empty");
      path.textContent = "";
      return;
    }

    var info = state.siteInfo;
    name.textContent = (info && info.title) || site.name || site.path;
    path.textContent = site.path;
  }

  function renderSiteMenu() {
    var list = el("site-menu-list");
    if (!list) return;
    list.innerHTML = "";

    if (!state.sites.length) {
      var empty = document.createElement("div");
      empty.className = "site-menu-empty";
      empty.textContent = t("sites.empty");
      list.appendChild(empty);
      return;
    }

    state.sites.forEach(function (site) {
      var isCurrent = site.path === state.currentSitePath;
      var item = document.createElement("button");
      item.type = "button";
      item.className = "site-menu-item" + (isCurrent ? " is-current" : "");
      item.setAttribute("role", "option");
      item.innerHTML =
        '<span class="site-menu-item-text">' +
        '<span class="site-menu-item-name"></span>' +
        '<span class="site-menu-item-path"></span>' +
        "</span>";

      item.querySelector(".site-menu-item-name").textContent =
        site.name || site.path;
      item.querySelector(".site-menu-item-path").textContent = site.path;

      if (isCurrent) {
        var badge = document.createElement("span");
        badge.className = "site-menu-badge";
        badge.textContent = t("sites.current");
        item.appendChild(badge);
      }

      item.addEventListener("click", function () {
        selectSite(site.path);
        closeSiteMenu();
      });
      list.appendChild(item);
    });
  }

  function toggleSiteMenu() {
    var menu = el("site-menu");
    var button = el("site-switcher-button");
    if (!menu) return;
    var open = menu.hasAttribute("hidden");
    if (open) {
      renderSiteMenu();
      menu.removeAttribute("hidden");
      if (button) button.setAttribute("aria-expanded", "true");
    } else {
      menu.setAttribute("hidden", "");
      if (button) button.setAttribute("aria-expanded", "false");
    }
  }

  function closeSiteMenu() {
    var menu = el("site-menu");
    if (menu && !menu.hasAttribute("hidden")) {
      menu.setAttribute("hidden", "");
      var button = el("site-switcher-button");
      if (button) button.setAttribute("aria-expanded", "false");
    }
  }

  // ------------------------------------------------------------ 站点动作

  function selectSite(path) {
    api("selectSite", path).then(function (result) {
      if (!result || !result.ok) {
        toast(t("common.error"), "error");
        return;
      }
      state.sites = result.sites || [];
      state.currentSitePath = result.currentSitePath || "";
      state.siteInfo = result.siteInfo || null;
      state.selectedPostPath = "";
      state.posts = [];
      state.log = [];
      render();
      refreshPosts();
    });
  }

  function addSiteByPath(path) {
    if (!path || !path.trim()) {
      toast(t("sites.addFailed"), "error");
      return;
    }
    api("addSite", path.trim()).then(function (result) {
      if (!result || !result.ok) {
        toast(t("sites.addFailed"), "error");
        return;
      }
      state.sites = result.sites || [];
      state.currentSitePath = result.currentSitePath || "";
      state.siteInfo = result.siteInfo || null;
      state.selectedPostPath = "";
      state.posts = [];
      render();
      refreshPosts();
      toast(t("sites.addSuccess"));
    });
  }

  function chooseSiteDirectory() {
    api("chooseSiteDirectory").then(function (result) {
      if (!result || !result.ok) return;
      addSiteByPath(result.path);
    });
  }

  function removeSite(path) {
    openModal({
      title: t("common.remove"),
      body: t("sites.removeConfirm"),
      actions: [
        { label: t("common.cancel") },
        {
          label: t("common.remove"),
          primary: true,
          onClick: function () {
            api("removeSite", path).then(function (result) {
              if (!result || !result.ok) {
                toast(t("common.error"), "error");
                return;
              }
              state.sites = result.sites || [];
              state.currentSitePath = result.currentSitePath || "";
              if (!state.currentSitePath) state.siteInfo = null;
              render();
              toast(t("sites.removeSuccess"));
            });
          },
        },
      ],
    });
  }

  // ------------------------------------------------------------ 总览

  function renderOverview(host, actionsHost) {
    if (!hasSite()) {
      host.innerHTML =
        '<div class="empty-state">' +
        '<span class="empty-state-icon">' +
        icon("folder", 21) +
        "</span>" +
        '<div class="empty-state-title"></div>' +
        '<div class="empty-state-hint"></div>' +
        '<button class="button is-primary" id="goto-sites">' +
        icon("plus", 14) +
        '<span></span>' +
        "</button>" +
        "</div>";
      host.querySelector(".empty-state-title").textContent = t("overview.noSite");
      host.querySelector(".empty-state-hint").textContent = t("overview.noSiteHint");
      var goto = host.querySelector("#goto-sites span");
      if (goto) goto.textContent = t("overview.goAddSite");
      host.querySelector("#goto-sites").addEventListener("click", function () {
        state.page = "sites";
        render();
      });
      return;
    }

    var info = state.siteInfo || {};
    var depsInstalled = !!info.dependenciesInstalled;

    var html = "";

    // 指标卡
    html += '<div class="stat-grid">';
    html += statCard("document", t("overview.posts"), String(info.postCount || 0), info.postCount ? "" : t("overview.noCommits"));
    html += statCard("package", t("overview.hexoVersion"), info.hexoVersion || t("overview.notDeclared"), t(state.hexoSourceKey || "hexoSource.path"));
    html += statCard("palette", t("overview.theme"), info.theme || t("overview.noTheme"), info.themeVersion || t("overview.noThemeVersion"));
    html += statCard("box", t("overview.buildOutput"), tf("overview.files", { count: info.buildFileCount || 0 }), info.hasBuildOutput ? t("overview.hasPublic") : t("overview.noPublic"));
    html += statCard(
      depsInstalled ? "check" : "warn",
      t("overview.dependencies"),
      depsInstalled ? t("overview.statInstalled") : t("overview.statNotInstalled"),
      depsInstalled ? t("overview.statInstalledHint") : t("overview.statNotInstalledHint"),
      depsInstalled ? "is-success" : "is-warning"
    );
    html += "</div>";

    // 依赖未安装提示
    if (!depsInstalled) {
      html +=
        '<div class="notice" style="margin-top:14px">' +
        icon("warn", 17) +
        "<div>" +
        '<div class="notice-title"></div>' +
        '<div class="notice-body"></div>' +
        "</div>" +
        '<div class="notice-actions"><button class="button is-small" id="open-site-folder"></button></div>' +
        "</div>";
    }

    // 站点详情
    html += '<div class="section" style="margin-top:18px"><div class="card">';
    html += '<div class="card-title">' + icon("info", 15) + '<span></span></div>';
    html += '<div class="detail-list">';
    html += detailRow(t("overview.path"), state.currentSitePath, true);
    html += detailRow(t("overview.hexoSource"), t(state.hexoSourceKey || "hexoSource.path"));
    html += detailRow(t("overview.commandPreview"), state.commandPreview || "", true);
    html += detailRow(
      t("overview.gitRepo"),
      info.isGitRepository ? t("overview.gitIsRepo") : t("overview.gitNotRepo")
    );
    html += detailRow(t("overview.remote"), info.gitRemote || t("overview.noRemote"));
    html += detailRow(t("overview.previewPort"), String(state.serverPort || 4000));
    html += "</div></div></div>";

    // 快捷操作
    html += '<div class="section"><div class="card">';
    html += '<div class="card-title">' + icon("cog", 15) + '<span></span></div>';
    html += '<div class="button-row">';
    html +=
      '<button class="button" id="act-generate">' +
      icon("hammer", 14) +
      '<span></span></button>';
    html +=
      '<button class="button" id="act-clean">' +
      icon("refresh", 14) +
      '<span></span></button>';
    html +=
      '<button class="button" id="act-preview">' +
      icon(state.serverRunning ? "stop" : "play", 14) +
      '<span></span></button>';
    html +=
      '<button class="button" id="act-open-preview">' +
      icon("globe", 14) +
      '<span></span></button>';
    html +=
      '<button class="button" id="act-open-folder">' +
      icon("folder", 14) +
      '<span></span></button>';
    html +=
      '<button class="button" id="act-refresh-git">' +
      icon("branch", 14) +
      '<span></span></button>';
    html += "</div>";

    if (state.log.length) {
      html +=
        '<div class="log-console" id="overview-log"></div>';
    }
    html += "</div></div>";

    // 最近提交
    if (state.commits && state.commits.length) {
      html += '<div class="section"><div class="card">';
      html += '<div class="card-title">' + icon("clock", 15) + '<span></span></div>';
      html += '<div class="commit-list">';
      state.commits.forEach(function (commit) {
        html +=
          '<div class="commit-row">' +
          '<span class="commit-hash">' +
          escapeHtml(commit.shortHash) +
          "</span>" +
          '<span class="commit-subject">' +
          escapeHtml(commit.subject) +
          "</span>" +
          '<span class="commit-date">' +
          escapeHtml(commit.date) +
          "</span>" +
          "</div>";
      });
      html += "</div></div></div>";
    }

    host.innerHTML = html;

    // 绑定文案
    var titleNodes = host.querySelectorAll(".card-title span");
    var cardTitles = [
      t("overview.siteDetails"),
      t("overview.actions"),
      t("overview.recentCommits"),
    ];
    titleNodes.forEach(function (node, index) {
      if (cardTitles[index]) node.textContent = cardTitles[index];
    });

    var noticeTitle = host.querySelector(".notice-title");
    if (noticeTitle) noticeTitle.textContent = t("overview.depsMissing");
    var noticeBody = host.querySelector(".notice-body");
    if (noticeBody) noticeBody.textContent = t("overview.depsMissingHint");
    var openFolderBtn = host.querySelector("#open-site-folder");
    if (openFolderBtn) openFolderBtn.textContent = t("common.openFolder");

    var buttons = [
      ["#act-generate", t("overview.generate")],
      ["#act-clean", t("overview.clean")],
      ["#act-preview", t(state.serverRunning ? "overview.stopPreview" : "overview.startPreview")],
      ["#act-open-preview", t("overview.openPreview")],
      ["#act-open-folder", t("common.openFolder")],
      ["#act-refresh-git", t("overview.refreshGit")],
    ];
    buttons.forEach(function (pair) {
      var node = host.querySelector(pair[0] + " span");
      if (node) node.textContent = pair[1];
    });

    var log = host.querySelector("#overview-log");
    if (log) log.textContent = state.log.join("\n");

    // 绑定动作
    bindClick(host, "#act-generate", function () {
      runHexo("runGenerate");
    });
    bindClick(host, "#act-clean", function () {
      runHexo("runClean");
    });
    bindClick(host, "#act-preview", function () {
      togglePreview();
    });
    bindClick(host, "#act-open-preview", function () {
      api("openPreviewPage");
    });
    bindClick(host, "#act-open-folder", function () {
      api("revealSiteDirectory", state.currentSitePath);
    });
    bindClick(host, "#act-refresh-git", function () {
      refreshGit();
    });
  }

  function statCard(iconName, label, value, caption, modifier) {
    return (
      '<div class="stat-card ' +
      (modifier || "") +
      '">' +
      '<div class="stat-card-head">' +
      icon(iconName, 14) +
      "<span>" +
      escapeHtml(label) +
      "</span></div>" +
      '<div class="stat-card-value">' +
      escapeHtml(value) +
      "</div>" +
      '<div class="stat-card-caption">' +
      escapeHtml(caption || "") +
      "</div></div>"
    );
  }

  function detailRow(label, value, mono) {
    return (
      '<div class="detail-label">' +
      escapeHtml(label) +
      '</div><div class="detail-value' +
      (mono ? " is-mono" : "") +
      '">' +
      escapeHtml(value) +
      "</div>"
    );
  }

  function bindClick(root, selector, handler) {
    var node = root.querySelector(selector);
    if (node) node.addEventListener("click", handler);
  }

  function runHexo(method) {
    api(method).then(function (result) {
      if (!result) {
        toast(t("common.error"), "error");
        return;
      }
      state.log = (result.output || "").split("\n").filter(Boolean);
      if (result.ok) {
        toast(t("result.success"));
        refreshOverview();
      } else {
        toast(result.error || t("result.failed"), "error");
        render();
      }
    });
  }

  function togglePreview() {
    if (state.serverRunning) {
      api("stopPreview").then(function () {
        state.serverRunning = false;
        render();
        toast(t("result.success"));
      });
      return;
    }

    api("startPreview").then(function (result) {
      if (!result || !result.ok) {
        toast(t("result.failed"), "error");
        return;
      }
      state.serverRunning = true;
      render();
      toast(t("result.success"));
    });
  }

  function refreshGit() {
    api("refreshGit").then(function (result) {
      if (!result || !result.ok) return;
      state.commits = result.commits || [];
      state.gitStatus = result.gitStatus || null;
      render();
    });
  }

  // ------------------------------------------------------------ 站点管理页

  function renderSites(host) {
    var html = "";

    html += '<div class="card">';
    html += '<div class="card-title">' + icon("folder", 15) + '<span></span></div>';
    html += '<div class="site-list" id="site-list"></div>';

    html +=
      '<div class="add-site-row">' +
      '<label class="field"><span class="field-label"></span>' +
      '<input class="input" id="add-site-input" type="text" /></label>' +
      '<button class="button" id="add-site-choose"></button>' +
      '<button class="button is-primary" id="add-site-confirm"></button>' +
      "</div>";

    html += "</div>";
    host.innerHTML = html;

    // 文案
    var title = host.querySelector(".card-title span");
    if (title) title.textContent = t("sites.title");

    renderSiteRows();

    var fieldLabel = host.querySelector(".add-site-row .field-label");
    if (fieldLabel) fieldLabel.textContent = t("sites.addPath");
    var input = host.querySelector("#add-site-input");
    if (input) input.placeholder = t("sites.pathPlaceholder");

    var chooseBtn = host.querySelector("#add-site-choose");
    if (chooseBtn) {
      chooseBtn.innerHTML = icon("folder", 14) + "<span></span>";
      chooseBtn.querySelector("span").textContent = t("sites.chooseDirectory");
      chooseBtn.addEventListener("click", chooseSiteDirectory);
    }

    var confirmBtn = host.querySelector("#add-site-confirm");
    if (confirmBtn) {
      confirmBtn.innerHTML = icon("plus", 14) + "<span></span>";
      confirmBtn.querySelector("span").textContent = t("common.add");
      confirmBtn.addEventListener("click", function () {
        addSiteByPath(input ? input.value : "");
      });
    }

    if (input) {
      input.addEventListener("keydown", function (event) {
        if (event.key === "Enter") addSiteByPath(input.value);
      });
    }
  }

  /** 站点列表的行。用 DOM 构建而不是拼字符串——路径里有引号和中文时拼字符串容易出错。 */
  function renderSiteRows() {
    var list = el("site-list");
    if (!list) return;
    list.innerHTML = "";

    if (!state.sites.length) {
      var empty = document.createElement("div");
      empty.className = "empty-state";
      empty.innerHTML =
        '<span class="empty-state-icon">' +
        icon("folder", 21) +
        "</span>" +
        '<div class="empty-state-title"></div>' +
        '<div class="empty-state-hint"></div>';
      empty.querySelector(".empty-state-title").textContent = t("sites.empty");
      empty.querySelector(".empty-state-hint").textContent = t("sites.emptyHint");
      list.appendChild(empty);
      return;
    }

    state.sites.forEach(function (site) {
      var isCurrent = isCurrentSite(site.path);

      var row = document.createElement("div");
      row.className = "site-row" + (isCurrent ? " is-current" : "");

      var iconWrap = document.createElement("span");
      iconWrap.className = "site-row-icon";
      iconWrap.innerHTML = icon("folder", 17);

      var body = document.createElement("div");
      body.className = "site-row-body";

      var nameRow = document.createElement("div");
      nameRow.className = "site-row-name";
      var nameNode = document.createElement("span");
      // 当前站点优先显示配置里的标题，其余显示目录名
      nameNode.textContent =
        (isCurrent && state.siteInfo && state.siteInfo.title) ||
        site.name ||
        site.path;
      nameRow.appendChild(nameNode);
      if (isCurrent) {
        var badge = document.createElement("span");
        badge.className = "badge";
        badge.textContent = t("sites.current");
        nameRow.appendChild(badge);
      }

      var pathNode = document.createElement("div");
      pathNode.className = "site-row-path";
      pathNode.textContent = site.path;

      body.appendChild(nameRow);
      body.appendChild(pathNode);

      var actions = document.createElement("div");
      actions.className = "site-row-actions";

      var selectBtn = document.createElement("button");
      selectBtn.type = "button";
      selectBtn.className = "button is-small";
      selectBtn.textContent = isCurrent ? t("sites.current") : t("sites.switch");
      selectBtn.disabled = isCurrent;
      selectBtn.addEventListener("click", function () {
        selectSite(site.path);
      });

      var revealBtn = document.createElement("button");
      revealBtn.type = "button";
      revealBtn.className = "button is-small";
      revealBtn.textContent = t("common.openFolder");
      revealBtn.addEventListener("click", function () {
        api("revealSiteDirectory", site.path);
      });

      var removeBtn = document.createElement("button");
      removeBtn.type = "button";
      removeBtn.className = "button is-small is-danger";
      removeBtn.textContent = t("common.remove");
      removeBtn.disabled = isCurrent;
      if (isCurrent) removeBtn.title = t("sites.requiresCurrent");
      removeBtn.addEventListener("click", function () {
        removeSite(site.path);
      });

      actions.appendChild(selectBtn);
      actions.appendChild(revealBtn);
      actions.appendChild(removeBtn);

      row.appendChild(iconWrap);
      row.appendChild(body);
      row.appendChild(actions);
      list.appendChild(row);
    });
  }

  function isCurrentSite(path) {
    return path === state.currentSitePath;
  }

  // ------------------------------------------------------------ 文章页

  function filteredPosts() {
    var keyword = state.postSearch.trim().toLowerCase();
    return state.posts.filter(function (post) {
      if (state.postFilter === "published" && post.draft) return false;
      if (state.postFilter === "draft" && !post.draft) return false;
      if (!keyword) return true;
      if (post.title.toLowerCase().indexOf(keyword) >= 0) return true;
      if ((post.body || "").toLowerCase().indexOf(keyword) >= 0) return true;
      for (var i = 0; i < post.tags.length; i++) {
        if (post.tags[i].toLowerCase().indexOf(keyword) >= 0) return true;
      }
      return false;
    });
  }

  function renderPosts(host, actionsHost) {
    var html = "";

    html += '<div class="posts-layout">';

    // 左：列表
    html += '<div class="posts-list-pane">';
    html +=
      '<input class="input" id="post-search" type="search" placeholder="" />';
    html += '<div class="segmented" id="post-filter">';
    ["all", "published", "draft"].forEach(function (key) {
      html +=
        '<button class="segmented-button" data-filter="' +
        key +
        '"></button>';
    });
    html += "</div>";
    html += '<div class="posts-list" id="post-list"></div>';
    html += "</div>";

    // 右：编辑器
    html += '<div class="posts-editor-pane" id="post-editor"></div>';
    html += "</div>";

    host.innerHTML = html;

    var search = host.querySelector("#post-search");
    search.placeholder = t("posts.searchPlaceholder");
    search.value = state.postSearch;
    search.addEventListener("input", function () {
      state.postSearch = search.value;
      renderPostList();
    });

    host.querySelectorAll("#post-filter .segmented-button").forEach(function (btn) {
      var key = btn.getAttribute("data-filter");
      btn.textContent = t("posts.filter." + key);
      btn.className =
        "segmented-button" + (state.postFilter === key ? " is-active" : "");
      btn.addEventListener("click", function () {
        state.postFilter = key;
        renderPostFilter();
        renderPostList();
      });
    });

    renderPostList();
    renderPostEditor();
  }

  function renderPostFilter() {
    document
      .querySelectorAll("#post-filter .segmented-button")
      .forEach(function (btn) {
        var key = btn.getAttribute("data-filter");
        btn.className =
          "segmented-button" + (state.postFilter === key ? " is-active" : "");
      });
  }

  function renderPostList() {
    var list = el("post-list");
    if (!list) return;
    list.innerHTML = "";

    var posts = filteredPosts();

    if (!state.posts.length) {
      list.innerHTML =
        '<div class="empty-state" style="padding:32px 12px">' +
        '<span class="empty-state-icon">' +
        icon("document", 21) +
        "</span>" +
        '<div class="empty-state-title"></div>' +
        '<div class="empty-state-hint"></div>' +
        "</div>";
      list.querySelector(".empty-state-title").textContent = t("posts.empty");
      list.querySelector(".empty-state-hint").textContent = t("posts.emptyHint");
      return;
    }

    if (!posts.length) {
      list.innerHTML =
        '<div class="empty-state" style="padding:32px 12px">' +
        '<div class="empty-state-title"></div>' +
        '<div class="empty-state-hint"></div>' +
        "</div>";
      list.querySelector(".empty-state-title").textContent = t("posts.noMatch");
      list.querySelector(".empty-state-hint").textContent = t("posts.noMatchHint");
      return;
    }

    posts.forEach(function (post) {
      var item = document.createElement("button");
      item.type = "button";
      item.className =
        "post-list-item" + (post.path === state.selectedPostPath ? " is-active" : "");

      var meta = [];
      meta.push(escapeHtml(post.date));
      meta.push(tf("common.wordCount", { count: post.wordCount }));
      if (post.tags.length) meta.push(escapeHtml(post.tags.join(", ")));

      item.innerHTML =
        '<div class="post-list-title">' +
        (post.draft ? '<span class="draft-pill"></span>' : "") +
        '<span class="post-list-title-text"></span>' +
        "</div>" +
        '<div class="post-list-meta"></div>' +
        '<div class="post-list-excerpt"></div>';

      item.querySelector(".post-list-title-text").textContent = post.title;
      item.querySelector(".post-list-meta").innerHTML = meta.join(" · ");
      item.querySelector(".post-list-excerpt").textContent = post.excerpt || "";
      if (post.draft) {
        item.querySelector(".draft-pill").textContent = t("posts.draft");
      }

      item.addEventListener("click", function () {
        selectPost(post.path);
      });
      list.appendChild(item);
    });
  }

  function selectPost(path) {
    state.selectedPostPath = path;
    state.dirty = false;
    renderPostList();
    renderPostEditor();
  }

  function renderPostEditor() {
    var host = el("post-editor");
    if (!host) return;

    var post = null;
    for (var i = 0; i < state.posts.length; i++) {
      if (state.posts[i].path === state.selectedPostPath) post = state.posts[i];
    }

    if (!post) {
      host.innerHTML =
        '<div class="card" style="flex:1;display:flex;align-items:center;justify-content:center">' +
        '<div class="empty-state">' +
        '<span class="empty-state-icon">' +
        icon("document", 21) +
        "</span>" +
        '<div class="empty-state-title"></div>' +
        '<div class="empty-state-hint"></div>' +
        "</div></div>";
      host.querySelector(".empty-state-title").textContent = t("posts.empty");
      host.querySelector(".empty-state-hint").textContent = t("posts.emptyHint");
      return;
    }

    var html = "";

    html += '<div class="editor-toolbar">';
    html += '<div class="segmented" id="editor-mode">';
    ["write", "split", "read"].forEach(function (mode) {
      html += '<button class="segmented-button" data-mode="' + mode + '"></button>';
    });
    html += "</div>";
    html += '<div class="editor-toolbar-spacer"></div>';
    html += '<button class="button is-small" id="post-reveal"></button>';
    html += '<button class="button is-small" id="post-toggle-draft"></button>';
    html += '<button class="button is-small is-danger" id="post-delete"></button>';
    html += '<button class="button is-primary is-small" id="post-save"></button>';
    html += "</div>";

    html += '<div class="editor-meta">';
    html +=
      '<div class="field editor-meta-title"><span class="field-label"></span>' +
      '<input class="input" id="post-title" type="text" /></div>';
    html +=
      '<div class="field"><span class="field-label"></span>' +
      '<input class="input" id="post-date" type="text" /></div>';
    html +=
      '<div class="field"><span class="field-label"></span>' +
      '<input class="input" id="post-tags" type="text" /></div>';
    html +=
      '<div class="field"><span class="field-label"></span>' +
      '<input class="input" id="post-categories" type="text" /></div>';
    html +=
      '<div class="field"><span class="field-label"></span>' +
      '<label class="switch"><input type="checkbox" id="post-draft" /><span></span></label></div>';
    html += "</div>";

    html += '<div class="editor-body" id="editor-body">';
    if (state.editorMode !== "read") {
      html +=
        '<div class="editor-pane">' +
        '<div class="editor-pane-label"></div>' +
        '<textarea class="editor-textarea" id="post-body" spellcheck="false"></textarea>' +
        "</div>";
    }
    if (state.editorMode !== "write") {
      html +=
        '<div class="editor-pane">' +
        '<div class="editor-pane-label"></div>' +
        '<div class="markdown-preview" id="post-preview"></div>' +
        "</div>";
    }
    html += "</div>";

    html +=
      '<div class="editor-footer">' +
      '<span id="post-wordcount"></span>' +
      '<span id="post-filesize"></span>' +
      '<span class="editor-footer-spacer"></span>' +
      '<span id="post-dirty"></span>' +
      "</div>";

    host.innerHTML = html;

    // 填值
    var titleInput = host.querySelector("#post-title");
    var dateInput = host.querySelector("#post-date");
    var tagsInput = host.querySelector("#post-tags");
    var categoriesInput = host.querySelector("#post-categories");
    var draftInput = host.querySelector("#post-draft");
    var bodyInput = host.querySelector("#post-body");

    titleInput.value = post.title;
    dateInput.value = post.date;
    tagsInput.value = post.tags.join(", ");
    categoriesInput.value = post.categories.join(", ");
    draftInput.checked = !!post.draft;
    if (bodyInput) bodyInput.value = post.body || "";

    // 文案
    var labels = host.querySelectorAll(".editor-meta .field-label");
    var labelTexts = [
      t("posts.newTitle"),
      t("posts.date"),
      t("posts.tags"),
      t("posts.categories"),
      t("posts.draft"),
    ];
    labels.forEach(function (node, index) {
      node.textContent = labelTexts[index] || "";
    });
    var draftSwitch = host.querySelector(".switch span");
    if (draftSwitch) draftSwitch.textContent = post.draft ? t("posts.draft") : t("posts.published");

    host.querySelectorAll("#editor-mode .segmented-button").forEach(function (btn) {
      var mode = btn.getAttribute("data-mode");
      btn.textContent = t(EDITOR_MODE_KEYS[mode] || "posts.write");
      btn.className =
        "segmented-button" + (state.editorMode === mode ? " is-active" : "");
      btn.addEventListener("click", function () {
        state.editorMode = mode;
        renderPostEditor();
      });
    });

    var paneLabels = host.querySelectorAll(".editor-pane-label");
    if (paneLabels[0]) paneLabels[0].textContent = t("posts.body");
    if (paneLabels[1]) paneLabels[1].textContent = t("posts.preview");

    var revealBtn = host.querySelector("#post-reveal");
    if (revealBtn) {
      revealBtn.textContent = t("posts.reveal");
      revealBtn.addEventListener("click", function () {
        api("revealPost", post.path);
      });
    }
    var toggleDraftBtn = host.querySelector("#post-toggle-draft");
    if (toggleDraftBtn) {
      toggleDraftBtn.textContent = t(post.draft ? "posts.publish" : "posts.markDraft");
      toggleDraftBtn.addEventListener("click", function () {
        draftInput.checked = !draftInput.checked;
        draftInput.dispatchEvent(new Event("change"));
      });
    }
    var deleteBtn = host.querySelector("#post-delete");
    if (deleteBtn) {
      deleteBtn.textContent = t("common.delete");
      deleteBtn.addEventListener("click", function () {
        confirmDeletePost(post);
      });
    }
    var saveBtn = host.querySelector("#post-save");
    if (saveBtn) {
      saveBtn.textContent = t("common.save");
      saveBtn.addEventListener("click", function () {
        saveCurrentPost();
      });
    }

    // 字数统计
    var wordCountNode = host.querySelector("#post-wordcount");
    var fileSizeNode = host.querySelector("#post-filesize");
    var dirtyNode = host.querySelector("#post-dirty");

    function updateCounts() {
      var text = bodyInput ? bodyInput.value : post.body || "";
      var count = countWords(text);
      if (wordCountNode) {
        wordCountNode.textContent = tf("common.wordCount", { count: count });
      }
      if (fileSizeNode) {
        fileSizeNode.textContent = tf("posts.fileSize", {
          size: formatBytes(post.byteSize)
        });
      }
      if (dirtyNode) {
        dirtyNode.textContent = state.dirty ? t("posts.unsavedChanges") : "";
      }
    }

    updateCounts();

    if (bodyInput) {
      bodyInput.addEventListener("input", function () {
        state.dirty = true;
        updateCounts();
        updatePreview();
      });
    }

    [titleInput, dateInput, tagsInput, categoriesInput].forEach(function (input) {
      input.addEventListener("input", function () {
        state.dirty = true;
        updateCounts();
      });
    });

    draftInput.addEventListener("change", function () {
      state.dirty = true;
      var label = host.querySelector(".switch span");
      if (label) {
        label.textContent = draftInput.checked ? t("posts.draft") : t("posts.published");
      }
      updateCounts();
    });

    // 预览渲染（后端渲染，front matter 不进正文）
    function updatePreview() {
      var preview = host.querySelector("#post-preview");
      if (!preview) return;
      var source = bodyInput ? bodyInput.value : post.body || "";
      api("renderMarkdown", source).then(function (result) {
        if (!result || !result.ok) {
          preview.textContent = "";
          return;
        }
        preview.innerHTML = result.html || "";
      });
    }

    updatePreview();
  }

  /**
   * 字数统计。
   *
   * 与后端的 `hexoman.model.word_count` 保持一致：中文按字算、西文按词算。
   * 前端先算一遍是为了实时反馈（打字时不必往返后端），最终保存时以文件为准。
   */
  function countWords(text) {
    if (!text) return 0;
    var withoutCode = text.replace(/```[\s\S]*?```/g, "").replace(/`/g, "");
    var cjk = (withoutCode.match(/[一-鿿぀-ヿ가-힯]/g) || []).length;
    var latin = (withoutCode.match(/[0-9A-Za-z]+/g) || []).length;
    return cjk + latin;
  }

  function confirmDeletePost(post) {
    openModal({
      title: t("common.delete"),
      body: t("posts.deleteConfirm"),
      actions: [
        { label: t("common.cancel") },
        {
          label: t("common.delete"),
          primary: true,
          onClick: function () {
            api("deletePost", post.path).then(function (result) {
              if (!result || !result.ok) {
                toast(t("common.error"), "error");
                return;
              }
              state.selectedPostPath = "";
              state.dirty = false;
              refreshPosts();
              toast(t("posts.deleteSuccess"));
            });
          },
        },
      ],
    });
  }

  function saveCurrentPost() {
    var post = null;
    for (var i = 0; i < state.posts.length; i++) {
      if (state.posts[i].path === state.selectedPostPath) post = state.posts[i];
    }
    if (!post) return;

    var title = el("post-title").value;
    var date = el("post-date").value;
    var tags = splitList(el("post-tags").value);
    var categories = splitList(el("post-categories").value);
    var isDraft = el("post-draft").checked;
    var bodyInput = el("post-body");
    var body = bodyInput ? bodyInput.value : post.body;

    api("savePost", post.path, title, body, date, tags, categories, isDraft).then(
      function (result) {
        if (!result || !result.ok) {
          toast(t("common.error"), "error");
          return;
        }
        state.dirty = false;
        refreshPosts();
        toast(t("posts.saveSuccess"));
      }
    );
  }

  function splitList(text) {
    return String(text || "")
      .split(/[,，]/)
      .map(function (item) {
        return item.trim();
      })
      .filter(function (item) {
        return item.length > 0;
      });
  }

  function newPostDialog() {
    openModal({
      title: t("posts.new"),
      fields: [
        { name: "title", label: t("posts.newTitle"), placeholder: t("posts.newTitlePlaceholder") },
        { name: "tags", label: t("posts.newTags"), placeholder: t("posts.newTagsHint") },
        { name: "categories", label: t("posts.newCategories"), placeholder: t("posts.newTagsHint") },
      ],
      actions: [
        { label: t("common.cancel") },
        {
          label: t("posts.create"),
          primary: true,
          onClick: function (values) {
            if (!values.title || !values.title.trim()) {
              toast(t("posts.newTitle"), "error");
              return false;
            }
            api(
              "createPost",
              values.title.trim(),
              splitList(values.tags),
              splitList(values.categories),
              "",
              false
            ).then(function (result) {
              if (!result || !result.ok) {
                toast(t("common.error"), "error");
                return;
              }
              toast(t("posts.createSuccess"));
              refreshPosts(function () {
                state.selectedPostPath = result.post.path;
                renderPostList();
                renderPostEditor();
              });
            });
          },
        },
      ],
    });
  }

  function refreshPosts(after) {
    api("listPosts").then(function (result) {
      if (!result || !result.ok) {
        state.posts = [];
        renderPostList();
        renderPostEditor();
        if (after) after();
        return;
      }
      state.posts = result.posts || [];
      state.tags = result.tags || [];
      state.categories = result.categories || [];
      renderPostList();
      renderPostEditor();
      if (after) after();
    });
  }

  function refreshOverview() {
    api("getOverview").then(function (result) {
      if (!result || !result.ok) return;
      state.siteInfo = result.siteInfo;
      state.hexoSourceKey = result.hexoSourceKey;
      state.commandPreview = result.commandPreview;
      state.commits = result.commits || [];
      state.gitStatus = result.gitStatus;
      state.serverRunning = !!result.serverRunning;
      render();
    });
  }

  // ------------------------------------------------------------ 页面管理

  function renderPages(host, actionsHost) {
    actionsHost.innerHTML =
      '<button class="button is-primary" id="new-page">' +
      icon("plus", 14) +
      "<span></span></button>";
    actionsHost.querySelector("span").textContent = t("pages.new");
    actionsHost.querySelector("#new-page").addEventListener("click", newPageDialog);

    host.innerHTML =
      '<div class="posts-layout">' +
      '<div class="posts-list-pane">' +
      '<div class="posts-list" id="page-list"></div>' +
      "</div>" +
      '<div class="posts-editor-pane" id="page-editor"></div>' +
      "</div>";

    renderPageList();
    renderPageEditor();

    if (!state.pages.length) refreshPages();
  }

  function refreshPages(after) {
    api("listPages").then(function (result) {
      if (!result || !result.ok) return;
      state.pages = result.pages || [];
      if (state.selectedPagePath) {
        var stillThere = state.pages.filter(function (item) {
          return item.path === state.selectedPagePath;
        }).length;
        if (!stillThere) state.selectedPagePath = "";
      }
      renderPageList();
      renderPageEditor();
      if (after) after();
    });
  }

  function renderPageList() {
    var list = el("page-list");
    if (!list) return;
    list.innerHTML = "";

    if (!state.pages.length) {
      list.innerHTML =
        '<div class="empty-state" style="padding:32px 12px">' +
        '<span class="empty-state-icon">' +
        icon("documents", 21) +
        "</span>" +
        '<div class="empty-state-title"></div>' +
        '<div class="empty-state-hint"></div>' +
        "</div>";
      list.querySelector(".empty-state-title").textContent = t("pages.empty");
      list.querySelector(".empty-state-hint").textContent = t("pages.emptyHint");
      return;
    }

    state.pages.forEach(function (item) {
      var button = document.createElement("button");
      button.type = "button";
      button.className =
        "post-list-item" + (item.path === state.selectedPagePath ? " is-active" : "");

      var kindKey = "pages.kind." + (item.kind || "indexed");
      button.innerHTML =
        '<div class="post-list-title">' +
        (item.isPost ? '<span class="draft-pill"></span>' : "") +
        '<span class="post-list-title-text"></span>' +
        "</div>" +
        '<div class="post-list-meta"></div>' +
        '<div class="post-list-excerpt"></div>';

      button.querySelector(".post-list-title-text").textContent = item.title || item.slug;
      var pill = button.querySelector(".draft-pill");
      if (pill) pill.textContent = t("pages.isPost");
      button.querySelector(".post-list-meta").textContent =
        t(kindKey) + " · " + item.relativePath;
      button.querySelector(".post-list-excerpt").textContent = item.url;

      button.addEventListener("click", function () {
        selectPage(item.path);
      });
      list.appendChild(button);
    });
  }

  function selectPage(path) {
    state.selectedPagePath = path;
    state.pageDirty = false;
    renderPageList();

    api("getPage", path).then(function (result) {
      if (!result || !result.ok) return;
      state.pageBody = result.body || "";
      state.pageFields = result.fields || [];
      renderPageEditor();

      api("getPageAssets", path).then(function (assets) {
        state.pageAssets = (assets && assets.assets) || [];
        renderPageEditor();
      });
      api("getPageReferences", path).then(function (refs) {
        state.pageReferences = (refs && refs.references) || [];
        renderPageEditor();
      });
    });
  }

  /** 一个 front-matter 字段的编辑控件。 */
  function pageFieldControl(field) {
    var common =
      ' data-key="' + escapeHtml(field.key) + '" data-kind="' + escapeHtml(field.kind) + '"';

    if (field.kind === "boolean") {
      var checked = String(field.value).toLowerCase() === "true";
      return (
        '<label class="switch">' +
        '<input type="checkbox" class="page-field"' +
        common +
        (checked ? " checked" : "") +
        " />" +
        "<span></span></label>"
      );
    }

    if (field.kind === "choice" && field.options && field.options.length) {
      var options = field.options
        .map(function (option) {
          return (
            '<option value="' +
            escapeHtml(option.value) +
            '"' +
            (option.value === field.value ? " selected" : "") +
            ">" +
            escapeHtml(option.label) +
            "</option>"
          );
        })
        .join("");
      return (
        '<select class="select page-field"' + common + ">" + options + "</select>"
      );
    }

    if (field.kind === "list") {
      var items = (field.items || []).join(", ");
      return (
        '<input class="input page-field"' +
        common +
        ' type="text" value="' +
        escapeHtml(items) +
        '" placeholder="' +
        escapeHtml(t("pages.fieldPlaceholder")) +
        '" />'
      );
    }

    if (field.kind === "multiline" || field.kind === "passthrough") {
      return (
        '<textarea class="textarea page-field"' +
        common +
        ">" +
        escapeHtml(field.value) +
        "</textarea>"
      );
    }

    return (
      '<input class="input page-field"' +
      common +
      ' type="text" value="' +
      escapeHtml(field.value) +
      '" placeholder="' +
      escapeHtml(t("pages.fieldPlaceholder")) +
      '" />'
    );
  }

  function renderPageEditor() {
    var editor = el("page-editor");
    if (!editor) return;

    if (!state.selectedPagePath) {
      editor.innerHTML =
        '<div class="empty-state"><span class="empty-state-icon">' +
        icon("documents", 21) +
        "</span><div class=\"empty-state-title\"></div><div class=\"empty-state-hint\"></div></div>";
      editor.querySelector(".empty-state-title").textContent = t("pages.listTitle");
      editor.querySelector(".empty-state-hint").textContent = t("pages.emptyHint");
      return;
    }

    var page = null;
    state.pages.forEach(function (item) {
      if (item.path === state.selectedPagePath) page = item;
    });
    if (!page) return;

    var html = "";
    html += '<div class="editor-toolbar">';
    html += '<span class="editor-pane-label">' + escapeHtml(page.relativePath) + "</span>";
    html += '<span class="editor-toolbar-spacer"></span>';
    html += '<button class="button is-small" id="save-page">' + icon("save", 13) + "<span></span></button>";
    html += '<button class="button is-small is-danger" id="delete-page">' + icon("trash", 13) + "<span></span></button>";
    html += "</div>";

    html += '<div class="section" style="padding:0 14px">';
    html += '<div class="card-title">' + icon("sliders", 15) + "<span></span></div>";
    if (!state.pageFields.length) {
      html += '<div class="detail-row"><span></span></div>';
    } else {
      html += '<div class="form-grid">';
      state.pageFields.forEach(function (field) {
        var label = field.label || field.key;
        html +=
          '<div class="field">' +
          '<div class="field-label">' +
          escapeHtml(label) +
          (field.isKnown ? "" : ' <span class="badge"></span>') +
          "</div>" +
          pageFieldControl(field) +
          (field.hint ? '<div class="detail-label">' + escapeHtml(field.hint) + "</div>" : "") +
          "</div>";
      });
      html += "</div>";
    }
    html += "</div>";

    html += '<div class="section" style="padding:0 14px">';
    html += '<div class="card-title">' + icon("pencil", 15) + "<span></span></div>";
    html += '<textarea class="textarea editor-textarea" id="page-body" spellcheck="false"></textarea>';
    html += "</div>";

    if (state.pageAssets.length) {
      html += '<div class="section" style="padding:0 14px">';
      html += '<div class="card-title">' + icon("package", 15) + "<span></span></div>";
      html += '<div class="detail-list">';
      state.pageAssets.forEach(function (asset) {
        html +=
          '<div class="detail-row"><span class="detail-label">' +
          escapeHtml(asset.kindLabel + " · " + asset.originLabel) +
          '</span><span class="detail-value">' +
          escapeHtml(asset.sitePath) +
          "</span></div>";
      });
      html += "</div></div>";
    }

    if (state.pageReferences.length) {
      html += '<div class="section" style="padding:0 14px">';
      html += '<div class="card-title">' + icon("branch", 15) + "<span></span></div>";
      html += '<div class="detail-list">';
      state.pageReferences.forEach(function (ref) {
        html +=
          '<div class="detail-row"><span class="detail-label">' +
          escapeHtml(ref.matchKindLabel) +
          '</span><span class="detail-value">' +
          escapeHtml(ref.postTitle) +
          "</span></div>";
      });
      html += "</div></div>";
    }

    editor.innerHTML = html;

    var titles = editor.querySelectorAll(".card-title span");
    var labels = [t("pages.fields"), t("pages.body")];
    if (state.pageAssets.length) labels.push(t("pages.assets"));
    if (state.pageReferences.length) labels.push(t("pages.references"));
    titles.forEach(function (node, index) {
      if (labels[index]) node.textContent = labels[index];
    });

    var badge = editor.querySelector(".badge");
    if (badge) badge.textContent = "?";

    var body = editor.querySelector("#page-body");
    body.value = state.pageBody;
    body.addEventListener("input", function () {
      state.pageBody = body.value;
      state.pageDirty = true;
    });

    var save = editor.querySelector("#save-page");
    save.querySelector("span").textContent = t("pages.save");
    save.addEventListener("click", savePage);

    var remove = editor.querySelector("#delete-page");
    remove.querySelector("span").textContent = t("pages.delete");
    remove.addEventListener("click", deletePage);
  }

  function collectPageFields() {
    var result = [];
    document.querySelectorAll(".page-field").forEach(function (node) {
      var key = node.getAttribute("data-key");
      var kind = node.getAttribute("data-kind");
      var value = "";
      if (node.type === "checkbox") {
        value = node.checked ? "true" : "false";
      } else {
        value = node.value;
      }
      result.push({ key: key, kind: kind, value: value });
    });
    return result;
  }

  function savePage() {
    if (!state.selectedPagePath) return;
    var fields = collectPageFields();
    api("savePage", state.selectedPagePath, state.pageBody, fields).then(function (result) {
      if (!result || !result.ok) {
        toast(t("common.error"), "error");
        return;
      }
      state.pageDirty = false;
      toast(t("common.saved"));
      refreshPages(function () {
        selectPage(state.selectedPagePath);
      });
    });
  }

  function deletePage() {
    if (!state.selectedPagePath) return;
    customDialog({
      title: t("pages.delete"),
      html: '<div class="notice-body">' + escapeHtml(t("pages.deleteConfirm")) + "</div>",
      confirmLabel: t("common.delete"),
      onConfirm: function () {
        api("deletePage", state.selectedPagePath).then(function (result) {
          if (!result || !result.ok) {
            toast(t("common.error"), "error");
            return;
          }
          state.selectedPagePath = "";
          state.pageFields = [];
          state.pageBody = "";
          toast(t("common.saved"));
          refreshPages();
        });
      },
    });
  }

  function newPageDialog() {
    customDialog({
      title: t("pages.new"),
      html:
        '<div class="modal-form">' +
        '<div class="field"><div class="field-label" id="np-title-label"></div>' +
        '<input class="input" id="np-title" type="text" /></div>' +
        '<div class="field"><div class="field-label" id="np-slug-label"></div>' +
        '<input class="input" id="np-slug" type="text" /></div>' +
        '<div class="detail-label" id="np-hint"></div>' +
        '<div class="field"><div class="field-label" id="np-layout-label"></div>' +
        '<select class="select" id="np-layout">' +
        '<option value="page">page</option>' +
        '<option value="post">post</option>' +
        '<option value="">(default)</option>' +
        "</select></div>" +
        "</div>",
      confirmLabel: t("pages.create"),
      onConfirm: function (modal) {
        var title = modal.querySelector("#np-title").value;
        var slug = modal.querySelector("#np-slug").value;
        var layout = modal.querySelector("#np-layout").value;
        api("createPage", slug, title, layout).then(function (result) {
          if (!result || !result.ok) {
            toast(result && result.message ? result.message : t("common.error"), "error");
            return;
          }
          toast(t("common.saved"));
          refreshPages(function () {
            selectPage(result.page.path);
          });
        });
      },
      onMount: function (modal) {
        modal.querySelector("#np-title-label").textContent = t("pages.newTitle");
        modal.querySelector("#np-slug-label").textContent = t("pages.newSlug");
        modal.querySelector("#np-hint").textContent = t("pages.newSlugHint");
        modal.querySelector("#np-layout-label").textContent = t("pages.newLayout");
      },
    });
  }

  // ------------------------------------------------------------ 构建与预览

  function renderBuild(host, actionsHost) {
    actionsHost.innerHTML = "";
    var html = "";

    html += '<div class="section"><div class="card">';
    html += '<div class="card-title">' + icon("hammer", 15) + "<span></span></div>";
    html += '<div class="button-row">';
    html += '<button class="button is-primary" id="build-generate">' + icon("play", 14) + "<span></span></button>";
    html += '<button class="button" id="build-clean">' + icon("refresh", 14) + "<span></span></button>";
    html += '<button class="button" id="build-preview">' + icon(state.serverRunning ? "stop" : "globe", 14) + "<span></span></button>";
    html += '<button class="button" id="build-open">' + icon("globe", 14) + "<span></span></button>";
    html += "</div>";
    html += '<div class="detail-list" style="margin-top:12px">';
    html +=
      '<div class="detail-row"><span class="detail-label">' +
      escapeHtml(t("build.port")) +
      '</span><span class="detail-value">' +
      (state.serverPort || 4000) +
      "</span></div>";
    html +=
      '<div class="detail-row"><span class="detail-label">' +
      escapeHtml(t("build.drafts")) +
      '</span><span class="detail-value">' +
      (state.previewDrafts ? "true" : "false") +
      "</span></div>";
    html += "</div>";
    html += '<div class="detail-label" style="margin-top:10px">' + escapeHtml(t("build.hint")) + "</div>";
    html += "</div></div>";

    html += '<div class="section"><div class="card">';
    html += '<div class="card-title">' + icon("terminal", 15) + "<span></span></div>";
    html += '<div class="log-console" id="build-log"></div>';
    html += "</div></div>";

    host.innerHTML = html;

    host.querySelectorAll(".card-title span")[0].textContent = t("nav.build");
    host.querySelectorAll(".card-title span")[1].textContent = t("build.output");

    host.querySelector("#build-generate span").textContent = t("build.generate");
    host.querySelector("#build-clean span").textContent = t("build.clean");
    host.querySelector("#build-preview span").textContent = state.serverRunning
      ? t("build.stopPreview")
      : t("build.preview");
    host.querySelector("#build-open span").textContent = t("build.openPreview");

    host.querySelector("#build-generate").addEventListener("click", function () {
      runBuildCommand("runGenerate");
    });
    host.querySelector("#build-clean").addEventListener("click", function () {
      runBuildCommand("runClean");
    });
    host.querySelector("#build-preview").addEventListener("click", togglePreview);
    host.querySelector("#build-open").addEventListener("click", function () {
      api("openPreviewPage").then(function (result) {
        if (!result || !result.ok) toast(t("common.error"), "error");
      });
    });

    var log = host.querySelector("#build-log");
    log.textContent = state.buildOutput || t("build.emptyOutput");
  }

  function runBuildCommand(method) {
    state.buildRunning = true;
    state.buildOutput = t("build.running");
    render();
    api(method).then(function (result) {
      state.buildRunning = false;
      state.buildOutput = (result && result.output) || "";
      if (!result || !result.ok) {
        state.buildOutput += "\n" + ((result && result.error) || t("common.error"));
        toast(t("result.failed"), "error");
      } else {
        toast(t("result.success"));
      }
      render();
    });
  }

  // ------------------------------------------------------------ 配置

  function renderConfig(host, actionsHost) {
    actionsHost.innerHTML =
      '<button class="button" id="config-reload">' + icon("refresh", 13) + "<span></span></button>";
    actionsHost.querySelector("span").textContent = t("common.refresh");
    actionsHost.querySelector("#config-reload").addEventListener("click", function () {
      refreshConfig(true);
    });

    host.innerHTML = '<div id="config-root"></div>';

    if (!state.configFiles.length) {
      refreshConfig();
      return;
    }
    renderConfigBody();
  }

  function refreshConfig(force) {
    api("listConfigFiles").then(function (result) {
      if (!result || !result.ok) return;
      state.configFiles = result.files || [];

      if (!state.configFiles.length) {
        renderConfigBody();
        return;
      }

      var exists = state.configFiles.filter(function (item) {
        return item.path === state.configPath;
      }).length;
      if (force || !exists) state.configPath = state.configFiles[0].path;

      loadConfigFile(state.configPath);
    });
  }

  function loadConfigFile(path) {
    api("getConfigFile", path).then(function (result) {
      if (!result || !result.ok) return;
      state.configPath = path;
      state.configRaw = result.file.contents || "";
      api("getConfigSchema", path).then(function (schema) {
        state.configFields = (schema && schema.fields) || [];
        api("getConfigSync").then(function (sync) {
          state.configSync = sync && sync.ok ? sync : null;
          renderConfigBody();
        });
      });
    });
  }

  function renderConfigBody() {
    var root = el("config-root");
    if (!root) return;

    if (!state.configFiles.length) {
      root.innerHTML =
        '<div class="empty-state"><span class="empty-state-icon">' +
        icon("sliders", 21) +
        "</span><div class=\"empty-state-title\"></div></div>";
      root.querySelector(".empty-state-title").textContent = t("config.noFiles");
      return;
    }

    var html = "";
    html += '<div class="segmented" id="config-tabs">';
    state.configFiles.forEach(function (file) {
      html +=
        '<button class="segmented-button' +
        (file.path === state.configPath ? " is-active" : "") +
        '" data-path="' +
        escapeHtml(file.path) +
        '"></button>';
    });
    html += "</div>";

    html += '<div class="segmented" id="config-modes">';
    ["fields", "raw"].forEach(function (mode) {
      html +=
        '<button class="segmented-button' +
        (state.configTab === mode ? " is-active" : "") +
        '" data-mode="' +
        mode +
        '"></button>';
    });
    html += "</div>";

    html += '<div class="section"><div class="card">';
    if (state.configTab === "raw") {
      html += '<textarea class="textarea editor-textarea" id="config-raw" spellcheck="false"></textarea>';
      html += '<div class="button-row" style="margin-top:10px">';
      html += '<button class="button is-primary" id="config-save">' + icon("save", 13) + "<span></span></button>";
      html += "</div>";
    } else {
      html += '<div class="form-grid" id="config-form">';
      state.configFields.forEach(function (field) {
        html += '<div class="field">';
        html += '<div class="field-label">' + escapeHtml(field.label) + "</div>";
        if (!field.isWritable) {
          html +=
            '<div class="detail-value">' +
            escapeHtml(field.readOnlyReason || t("config.readonly")) +
            (field.childCount ? " · " + field.childCount : "") +
            "</div>";
        } else if (field.kind === "boolean") {
          html +=
            '<label class="switch"><input type="checkbox" class="config-field" data-id="' +
            escapeHtml(field.id) +
            '"' +
            (String(field.value).toLowerCase() === "true" ? " checked" : "") +
            " /><span></span></label>";
        } else if (field.kind === "choice" && field.options && field.options.length) {
          html +=
            '<select class="select config-field" data-id="' + escapeHtml(field.id) + '">';
          field.options.forEach(function (option) {
            html +=
              '<option value="' +
              escapeHtml(option.value) +
              '"' +
              (option.value === field.value ? " selected" : "") +
              ">" +
              escapeHtml(option.label) +
              "</option>";
          });
          html += "</select>";
        } else {
          html +=
            '<input class="input config-field" data-id="' +
            escapeHtml(field.id) +
            '" type="text" value="' +
            escapeHtml(field.value) +
            '" />';
        }
        if (field.doc && field.doc.summary) {
          html += '<div class="detail-label">' + escapeHtml(field.doc.summary) + "</div>";
        } else if (field.hint) {
          html += '<div class="detail-label">' + escapeHtml(field.hint) + "</div>";
        }
        html += "</div>";
      });
      html += "</div>";
    }
    html += "</div></div>";

    // 同步面板
    if (state.configSync) {
      html += '<div class="section"><div class="card">';
      html += '<div class="card-title">' + icon("refresh", 15) + "<span></span></div>";
      html += '<div class="detail-label"></div>';
      var diffs = state.configSync.differences || [];
      var themeOnly = state.configSync.themeOnly || [];
      if (diffs.length) {
        html += '<div class="detail-list">';
        diffs.forEach(function (item) {
          html +=
            '<div class="detail-row"><span class="detail-label">' +
            escapeHtml(item.label) +
            '</span><span class="detail-value">' +
            escapeHtml(item.themeDisplay) +
            " → " +
            escapeHtml(item.siteDisplay) +
            "</span></div>";
        });
        html += "</div>";
        html += '<div class="button-row" style="margin-top:10px">';
        html += '<button class="button is-primary" id="config-sync-apply">' + icon("check", 13) + "<span></span></button>";
        html += "</div>";
      }
      if (themeOnly.length) {
        html += '<div class="detail-list" style="margin-top:12px">';
        themeOnly.forEach(function (item) {
          html +=
            '<div class="detail-row"><span class="detail-label">' +
            escapeHtml(item.label) +
            '</span><span class="detail-value">' +
            escapeHtml(item.value) +
            '</span><button class="button is-small" data-move="' +
            escapeHtml(item.key) +
            '" data-value="' +
            escapeHtml(item.value) +
            '"></button></div>';
        });
        html += "</div>";
      }
      html += "</div></div>";
    }

    root.innerHTML = html;

    // 配置文件切换
    root.querySelectorAll("#config-tabs .segmented-button").forEach(function (button) {
      var path = button.getAttribute("data-path");
      var file = null;
      state.configFiles.forEach(function (item) {
        if (item.path === path) file = item;
      });
      button.textContent = file ? file.name : path;
      button.addEventListener("click", function () {
        state.configPath = path;
        loadConfigFile(path);
      });
    });

    // 表单 / 原文切换
    root.querySelectorAll("#config-modes .segmented-button").forEach(function (button) {
      var mode = button.getAttribute("data-mode");
      button.textContent = mode === "fields" ? t("config.fields") : t("config.raw");
      button.addEventListener("click", function () {
        state.configTab = mode;
        renderConfigBody();
      });
    });

    var raw = root.querySelector("#config-raw");
    if (raw) {
      raw.value = state.configRaw;
      raw.addEventListener("input", function () {
        state.configRaw = raw.value;
      });
    }

    var save = root.querySelector("#config-save");
    if (save) {
      save.querySelector("span").textContent = t("config.save");
      save.addEventListener("click", function () {
        api("saveConfigFile", state.configPath, state.configRaw).then(function (result) {
          if (!result || !result.ok) {
            toast(t("common.error"), "error");
            return;
          }
          toast(t("common.saved"));
          loadConfigFile(state.configPath);
        });
      });
    }

    // 单个值：改变即写回（只动那一行）
    root.querySelectorAll(".config-field").forEach(function (node) {
      node.addEventListener("change", function () {
        var id = node.getAttribute("data-id");
        var value = node.type === "checkbox" ? (node.checked ? "true" : "false") : node.value;
        api("updateConfigValue", state.configPath, id, value).then(function (result) {
          if (!result || !result.ok) {
            toast(t("common.error"), "error");
            return;
          }
          toast(t("config.fieldSaved"));
          loadConfigFile(state.configPath);
        });
      });
    });

    var syncApply = root.querySelector("#config-sync-apply");
    if (syncApply) {
      syncApply.querySelector("span").textContent = t("config.syncApply");
      syncApply.addEventListener("click", function () {
        api("applyConfigSync").then(function (result) {
          if (!result || !result.ok) {
            toast(t("common.error"), "error");
            return;
          }
          toast(result.changed && result.changed.length ? t("common.saved") : t("config.syncNothing"));
          loadConfigFile(state.configPath);
        });
      });
    }

    root.querySelectorAll("[data-move]").forEach(function (button) {
      button.textContent = t("config.moveToSite");
      button.addEventListener("click", function () {
        var key = button.getAttribute("data-move");
        var value = button.getAttribute("data-value");
        api("applyThemeOnlyToSite", key, value).then(function (result) {
          if (!result || !result.ok) {
            toast(t("common.error"), "error");
            return;
          }
          toast(t("common.saved"));
          loadConfigFile(state.configPath);
        });
      });
    });

    var cardTitles = root.querySelectorAll(".card-title span");
    if (cardTitles.length) cardTitles[0].textContent = t("config.syncTitle");
    var hint = root.querySelector(".section .detail-label");
    if (hint) hint.textContent = t("config.syncHint");
  }

  // ------------------------------------------------------------ 主题

  function renderTheme(host, actionsHost) {
    actionsHost.innerHTML =
      '<button class="button" id="theme-reload">' + icon("refresh", 13) + "<span></span></button>";
    actionsHost.querySelector("span").textContent = t("common.refresh");
    actionsHost.querySelector("#theme-reload").addEventListener("click", function () {
      refreshThemes();
      searchThemes(state.themeQuery);
    });

    host.innerHTML = '<div id="theme-root"></div>';
    refreshThemes();
  }

  function refreshThemes() {
    api("listThemes").then(function (result) {
      if (!result || !result.ok) return;
      state.themes = result.themes || [];
      state.activeTheme = result.activeTheme || "";
      renderThemeBody();
      if (!state.themeResults.length) searchThemes("");
    });
  }

  function searchThemes(query) {
    state.themeQuery = query;
    api("searchThemes", query).then(function (result) {
      if (!result || !result.ok) return;
      state.themeResults = result.results || [];
      state.themeOnline = !!result.online;
      renderThemeBody();
    });
  }

  function renderThemeBody() {
    var root = el("theme-root");
    if (!root) return;

    var html = "";

    html += '<div class="section"><div class="card">';
    html += '<div class="card-title">' + icon("palette", 15) + "<span></span></div>";
    if (!state.themes.length) {
      html += '<div class="detail-row"><span class="detail-label"></span></div>';
    } else {
      html += '<div class="detail-list">';
      state.themes.forEach(function (theme) {
        html += '<div class="detail-row">';
        html +=
          '<span class="detail-label">' +
          escapeHtml(theme.name) +
          (theme.isActive ? ' <span class="badge"></span>' : "") +
          "</span>";
        html +=
          '<span class="detail-value">' +
          escapeHtml(tf("theme.version", { version: theme.version || "-" })) +
          "</span>";
        html += '<span class="button-row">';
        if (!theme.isActive) {
          html +=
            '<button class="button is-small" data-activate="' +
            escapeHtml(theme.packageName) +
            '"></button>';
        }
        if (!theme.hasSiteConfig) {
          html +=
            '<button class="button is-small" data-create-config="' +
            escapeHtml(theme.packageName) +
            '"></button>';
        }
        html += "</span></div>";
      });
      html += "</div>";
    }
    html += "</div></div>";

    html += '<div class="section"><div class="card">';
    html += '<div class="card-title">' + icon("box", 15) + "<span></span></div>";
    html +=
      '<input class="input" id="theme-search" type="search" placeholder="' +
      escapeHtml(t("theme.searchPlaceholder")) +
      '" value="' +
      escapeHtml(state.themeQuery) +
      '" />';
    html +=
      '<div class="detail-label" style="margin-top:8px">' +
      escapeHtml(state.themeOnline ? t("theme.onlineOn") : t("theme.onlineOff")) +
      "</div>";
    html += '<div class="detail-list" style="margin-top:10px">';
    state.themeResults.forEach(function (item) {
      html += '<div class="detail-row">';
      html += '<span class="detail-label">' + escapeHtml(item.shortName || item.name) + "</span>";
      html += '<span class="detail-value">' + escapeHtml(item.description || "") + "</span>";
      html += "</div>";
    });
    html += "</div>";
    html += "</div></div>";

    root.innerHTML = html;

    var titles = root.querySelectorAll(".card-title span");
    if (titles[0]) titles[0].textContent = t("theme.installed");
    if (titles[1]) titles[1].textContent = t("theme.market");

    root.querySelectorAll(".badge").forEach(function (node) {
      node.textContent = t("theme.active");
    });

    root.querySelectorAll("[data-activate]").forEach(function (button) {
      button.textContent = t("theme.activate");
      button.addEventListener("click", function () {
        var name = button.getAttribute("data-activate");
        api("switchTheme", name).then(function (result) {
          if (!result || !result.ok) {
            toast(t("common.error"), "error");
            return;
          }
          toast(tf("theme.switched", { name: result.activeTheme }));
          refreshThemes();
        });
      });
    });

    root.querySelectorAll("[data-create-config]").forEach(function (button) {
      button.textContent = t("theme.createConfig");
      button.addEventListener("click", function () {
        var name = button.getAttribute("data-create-config");
        api("createThemeConfig", name).then(function (result) {
          if (!result || !result.ok) {
            toast(t("common.error"), "error");
            return;
          }
          toast(t("common.saved"));
          refreshThemes();
        });
      });
    });

    var search = root.querySelector("#theme-search");
    if (search) {
      search.addEventListener("keydown", function (event) {
        if (event.key === "Enter") searchThemes(search.value);
      });
    }
  }

  // ------------------------------------------------------------ 备份

  function renderBackup(host, actionsHost) {
    actionsHost.innerHTML =
      '<button class="button is-primary" id="backup-create">' + icon("archive", 13) + "<span></span></button>";
    actionsHost.querySelector("span").textContent = t("backup.create");
    actionsHost.querySelector("#backup-create").addEventListener("click", function () {
      api("createBackup").then(function (result) {
        if (!result || !result.ok) {
          toast(t("common.error"), "error");
          return;
        }
        toast(t("common.saved"));
        refreshBackups();
      });
    });

    host.innerHTML = '<div id="backup-root"></div>';
    refreshBackups();
  }

  function refreshBackups() {
    api("getBackupPlan").then(function (plan) {
      state.backupPlan = plan && plan.ok ? plan.plan : null;
      api("listBackups").then(function (result) {
        state.backups = (result && result.backups) || [];
        renderBackupBody();
      });
    });
  }

  function renderBackupBody() {
    var root = el("backup-root");
    if (!root) return;

    var html = "";
    if (state.backupPlan) {
      html += '<div class="notice"><div><div class="notice-title"></div>';
      html += '<div class="notice-body"></div></div></div>';
    }

    html += '<div class="section"><div class="card">';
    html += '<div class="card-title">' + icon("archive", 15) + "<span></span></div>";
    if (!state.backups.length) {
      html +=
        '<div class="empty-state" style="padding:24px 12px">' +
        '<div class="empty-state-title"></div></div>';
    } else {
      html += '<div class="detail-list">';
      state.backups.forEach(function (item) {
        html += '<div class="detail-row">';
        html += '<span class="detail-label">' + escapeHtml(item.displayName) + "</span>";
        html +=
          '<span class="detail-value">' +
          escapeHtml(item.formattedSize) +
          (item.fileCount ? " · " + tf("backup.files", { count: item.fileCount }) : "") +
          "</span>";
        html += '<span class="button-row">';
        html += '<button class="button is-small" data-restore="' + escapeHtml(item.path) + '"></button>';
        html += '<button class="button is-small is-danger" data-drop="' + escapeHtml(item.path) + '"></button>';
        html += "</span></div>";
      });
      html += "</div>";
    }
    html += "</div></div>";

    root.innerHTML = html;

    if (state.backupPlan) {
      root.querySelector(".notice-title").textContent = t("backup.list");
      root.querySelector(".notice-body").textContent = tf("backup.planSummary", {
        files: state.backupPlan.includedCount,
        size: state.backupPlan.includedDescription,
      });
    }

    var titles = root.querySelectorAll(".card-title span");
    if (titles[0]) titles[0].textContent = t("backup.list");

    if (!state.backups.length) {
      var empty = root.querySelector(".empty-state-title");
      if (empty) empty.textContent = t("backup.empty");
    }

    root.querySelectorAll("[data-restore]").forEach(function (button) {
      button.textContent = t("backup.restore");
      button.addEventListener("click", function () {
        var path = button.getAttribute("data-restore");
        customDialog({
          title: t("backup.restore"),
          html: '<div class="notice-body">' + escapeHtml(t("backup.restoreConfirm")) + "</div>",
          confirmLabel: t("common.confirm"),
          onConfirm: function () {
            api("restoreBackup", path).then(function (result) {
              if (!result || !result.ok) {
                toast(t("common.error"), "error");
                return;
              }
              toast(t("common.saved"));
              refreshBackups();
            });
          },
        });
      });
    });

    root.querySelectorAll("[data-drop]").forEach(function (button) {
      button.textContent = t("common.delete");
      button.addEventListener("click", function () {
        var path = button.getAttribute("data-drop");
        customDialog({
          title: t("common.delete"),
          html: '<div class="notice-body">' + escapeHtml(t("backup.deleteConfirm")) + "</div>",
          confirmLabel: t("common.delete"),
          onConfirm: function () {
            api("deleteBackup", path).then(function () {
              refreshBackups();
            });
          },
        });
      });
    });
  }

  // ------------------------------------------------------------ 环境

  function renderEnvironment(host, actionsHost) {
    actionsHost.innerHTML =
      '<button class="button" id="env-refresh">' + icon("refresh", 13) + "<span></span></button>";
    actionsHost.querySelector("span").textContent = t("environment.refresh");
    actionsHost.querySelector("#env-refresh").addEventListener("click", function () {
      refreshEnvironment(true);
    });

    host.innerHTML = '<div id="env-root"></div>';
    if (!state.envSections.length) {
      api("getEnvironmentDocs").then(function (docs) {
        state.envSections = (docs && docs.sections) || [];
        refreshEnvironment(false);
      });
    } else {
      refreshEnvironment(false);
    }
  }

  function refreshEnvironment(refresh) {
    api("inspectEnvironment", refresh).then(function (result) {
      state.toolchain = result && result.ok ? result.toolchain : null;
      renderEnvironmentBody();
    });
  }

  function renderEnvironmentBody() {
    var root = el("env-root");
    if (!root) return;

    var html = "";
    var tools = state.toolchain || {};

    html += '<div class="section"><div class="card">';
    html += '<div class="card-title">' + icon("terminal", 15) + "<span></span></div>";
    html += '<div class="detail-list">';
    ["node", "npm", "npx", "globalHexo", "git"].forEach(function (key) {
      var probe = tools[key];
      if (!probe) return;
      html +=
        '<div class="detail-row"><span class="detail-label">' +
        escapeHtml(probe.name) +
        '</span><span class="detail-value">' +
        escapeHtml(probe.displayVersion || "") +
        "</span></div>";
    });
    var env = tools.environment || {};
    if (env.pathSummary) {
      html +=
        '<div class="detail-row"><span class="detail-label">' +
        escapeHtml(t("environment.path")) +
        '</span><span class="detail-value">' +
        escapeHtml(env.pathSummary) +
        "</span></div>";
    }
    if (env.rcSummary) {
      html +=
        '<div class="detail-row"><span class="detail-label">' +
        escapeHtml(t("environment.rcFiles")) +
        '</span><span class="detail-value">' +
        escapeHtml(env.rcSummary) +
        "</span></div>";
    }
    html += "</div></div></div>";

    html += '<div class="section"><div class="card">';
    html += '<div class="card-title">' + icon("warn", 15) + "<span></span></div>";
    var warnings = tools.warnings || [];
    if (!warnings.length) {
      html += '<div class="detail-value"></div>';
    } else {
      warnings.forEach(function (warning) {
        html += '<div class="notice" style="margin-top:10px"><div><div class="notice-body"></div></div></div>';
      });
    }
    html += "</div></div>";

    state.envSections.forEach(function (section) {
      html += '<div class="section"><div class="card">';
      html += '<div class="card-title">' + icon("info", 15) + "<span></span></div>";
      html += '<div class="detail-value">' + escapeHtml(section.summary) + "</div>";
      if (section.bullets && section.bullets.length) {
        html += '<div class="detail-list" style="margin-top:8px">';
        section.bullets.forEach(function (bullet) {
          html += '<div class="detail-row"><span class="detail-value">' + escapeHtml(bullet) + "</span></div>";
        });
        html += "</div>";
      }
      if (section.commands && section.commands.length) {
        html += '<div class="detail-list" style="margin-top:8px">';
        section.commands.forEach(function (command) {
          html +=
            '<div class="detail-row"><span class="detail-label">' +
            escapeHtml(command.description) +
            '</span><span class="detail-value">' +
            escapeHtml(command.command) +
            "</span></div>";
        });
        html += "</div>";
      }
      html += "</div></div>";
    });

    root.innerHTML = html;

    var titles = root.querySelectorAll(".card-title span");
    if (titles[0]) titles[0].textContent = t("environment.tools");
    if (titles[1]) titles[1].textContent = t("environment.warnings");

    var noWarnings = root.querySelector(".detail-value");
    if (noWarnings && !(tools.warnings || []).length) {
      noWarnings.textContent = t("environment.noWarnings");
    }

    var bodies = root.querySelectorAll(".notice-body");
    (tools.warnings || []).forEach(function (warning, index) {
      if (bodies[index]) bodies[index].textContent = warning;
    });
  }

  // ------------------------------------------------------------ Git

  function renderGit(host, actionsHost) {
    actionsHost.innerHTML =
      '<button class="button" id="git-refresh">' + icon("refresh", 13) + "<span></span></button>";
    actionsHost.querySelector("span").textContent = t("common.refresh");
    actionsHost.querySelector("#git-refresh").addEventListener("click", function () {
      refreshGitPage();
    });

    host.innerHTML = '<div id="git-root"></div>';
    refreshGitPage();
  }

  function refreshGitPage() {
    api("refreshGit").then(function (result) {
      if (!result || !result.ok) {
        state.gitStatus = null;
        state.commits = [];
      } else {
        state.gitStatus = result.gitStatus;
        state.commits = result.commits || [];
      }
      renderGitBody();
    });
  }

  function renderGitBody() {
    var root = el("git-root");
    if (!root) return;

    var html = "";
    var status = state.gitStatus;

    html += '<div class="section"><div class="card">';
    html += '<div class="card-title">' + icon("branch", 15) + "<span></span></div>";
    if (!status) {
      html += '<div class="detail-value"></div>';
    } else {
      html += '<div class="detail-list">';
      html +=
        '<div class="detail-row"><span class="detail-label">' +
        escapeHtml(t("git.status")) +
        '</span><span class="detail-value">' +
        (status.isClean ? escapeHtml(t("git.clean")) : tf("git.changes", { count: status.changeCount })) +
        "</span></div>";
      if (status.branch) {
        html +=
          '<div class="detail-row"><span class="detail-label">branch</span><span class="detail-value">' +
          escapeHtml(status.branch) +
          "</span></div>";
      }
      html += "</div>";
    }
    html += '<div class="field" style="margin-top:12px">';
    html += '<div class="field-label" id="git-message-label"></div>';
    html += '<input class="input" id="git-message" type="text" />';
    html += "</div>";
    html += '<div class="button-row">';
    html += '<button class="button is-primary" id="git-commit">' + icon("check", 13) + "<span></span></button>";
    html += '<button class="button" id="git-push">' + icon("globe", 13) + "<span></span></button>";
    html += '<button class="button" id="git-pull">' + icon("refresh", 13) + "<span></span></button>";
    html += "</div>";
    html += "</div></div>";

    if (state.commits.length) {
      html += '<div class="section"><div class="card">';
      html += '<div class="card-title">' + icon("clock", 15) + "<span></span></div>";
      html += '<div class="commit-list">';
      state.commits.forEach(function (commit) {
        html +=
          '<div class="commit-row"><span class="commit-hash">' +
          escapeHtml(commit.shortHash || "") +
          '</span><span class="commit-subject">' +
          escapeHtml(commit.subject || "") +
          '</span><span class="commit-date">' +
          escapeHtml(commit.date || "") +
          "</span></div>";
      });
      html += "</div></div></div>";
    }

    root.innerHTML = html;

    var titles = root.querySelectorAll(".card-title span");
    if (titles[0]) titles[0].textContent = t("git.status");
    if (titles[1]) titles[1].textContent = t("git.commits");

    if (!status) {
      var value = root.querySelector(".detail-value");
      if (value) value.textContent = t("git.notRepo");
    }

    root.querySelector("#git-message-label").textContent = t("git.message");
    root.querySelector("#git-commit span").textContent = t("git.commit");
    root.querySelector("#git-push span").textContent = t("git.push");
    root.querySelector("#git-pull span").textContent = t("git.pull");

    root.querySelector("#git-commit").addEventListener("click", function () {
      var message = root.querySelector("#git-message").value;
      api("commitGit", message).then(function (result) {
        if (!result || !result.ok) {
          toast(t("result.failed"), "error");
          return;
        }
        toast(t("result.success"));
        refreshGitPage();
      });
    });

    root.querySelector("#git-push").addEventListener("click", function () {
      api("pushGit").then(function (result) {
        toast(result && result.ok ? t("result.success") : t("result.failed"), result && result.ok ? "" : "error");
        refreshGitPage();
      });
    });

    root.querySelector("#git-pull").addEventListener("click", function () {
      api("pullGit").then(function (result) {
        toast(result && result.ok ? t("result.success") : t("result.failed"), result && result.ok ? "" : "error");
        refreshGitPage();
      });
    });
  }

  // ------------------------------------------------------------ 占位页

  function renderPlaceholder(host, titleKey) {
    host.innerHTML =
      '<div class="empty-state">' +
      '<span class="empty-state-icon">' +
      icon("cog", 21) +
      "</span>" +
      '<div class="empty-state-title"></div>' +
      '<div class="empty-state-hint"></div>' +
      "</div>";
    host.querySelector(".empty-state-title").textContent = t("common.notImplemented");
    host.querySelector(".empty-state-hint").textContent = t("common.notImplementedDetail");
  }

  // ------------------------------------------------------------ 总渲染

  function render() {
    renderNav();
    renderLanguageToggle();
    renderSiteSwitcher();

    var titleNode = el("content-title");
    var actionsHost = el("content-head-actions");
    var body = el("content-body");

    var titleKey = "nav." + state.page;
    if (state.page === "sites") titleKey = "nav.sites";
    if (titleNode) titleNode.textContent = t(titleKey);
    if (actionsHost) actionsHost.innerHTML = "";

    if (!hasSite() && state.page !== "sites") {
      // 没选站点时，除了站点管理页都引导回站点管理
      body.innerHTML =
        '<div class="empty-state">' +
        '<span class="empty-state-icon">' +
        icon("folder", 21) +
        "</span>" +
        '<div class="empty-state-title"></div>' +
        '<div class="empty-state-hint"></div>' +
        '<button class="button is-primary" id="goto-sites-2"></button>' +
        "</div>";
      body.querySelector(".empty-state-title").textContent = t("overview.noSite");
      body.querySelector(".empty-state-hint").textContent = t("overview.noSiteHint");
      var goto2 = body.querySelector("#goto-sites-2");
      goto2.innerHTML = icon("plus", 14) + "<span></span>";
      goto2.querySelector("span").textContent = t("overview.goAddSite");
      goto2.addEventListener("click", function () {
        state.page = "sites";
        render();
      });
      return;
    }

    switch (state.page) {
      case "sites":
        renderSites(body);
        break;
      case "overview":
        renderOverview(body, actionsHost);
        break;
      case "posts":
        renderPosts(body, actionsHost);
        break;
      case "pages":
        renderPages(body, actionsHost);
        break;
      case "build":
        renderBuild(body, actionsHost);
        break;
      case "config":
        renderConfig(body, actionsHost);
        break;
      case "theme":
        renderTheme(body, actionsHost);
        break;
      case "git":
        renderGit(body, actionsHost);
        break;
      case "backup":
        renderBackup(body, actionsHost);
        break;
      case "environment":
        renderEnvironment(body, actionsHost);
        break;
      default:
        renderPlaceholder(body, state.page);
        break;
    }
  }

  // ------------------------------------------------------------ 启动

  /**
   * 等 pywebview 把 JS API 注入进来。
   *
   * pywebview 不会在 DOMContentLoaded 时就把 ``window.pywebview.api`` 挂好——
   * 它在 WebView 初始化完成之后才注入，并触发 ``pywebviewready`` 事件。
   * 在那之前调用后端方法会拿到 undefined，界面就变成一屏 key 原文。
   *
   * 三种情况：
   *
   * 1. 已经有后端（浏览器预览里注入的假后端）——立刻返回。
   * 2. ``window.pywebview`` 在但 ``api`` 还没到——等 ``pywebviewready``。
   * 3. ``window.pywebview`` 压根不在（纯浏览器）——短等一下就返回 null，
   *    不然界面要白等 3 秒才画出来。
   */
  function waitForBackend() {
    return new Promise(function (resolve) {
      // 1. 已经有后端
      if (window.hexoman) {
        resolve(window.hexoman);
        return;
      }
      if (window.pywebview && window.pywebview.api) {
        resolve(window.pywebview.api);
        return;
      }

      var settled = false;
      var pywebviewSeen = !!window.pywebview;

      function done(value) {
        if (settled) return;
        settled = true;
        resolve(value);
      }

      window.addEventListener("pywebviewready", function () {
        done(window.pywebview ? window.pywebview.api : null);
      });

      // 2/3. 轮询判断属于哪种情况
      var elapsed = 0;
      var timer = setInterval(function () {
        elapsed += 50;

        if (window.pywebview) {
          pywebviewSeen = true;
          if (window.pywebview.api) {
            clearInterval(timer);
            done(window.pywebview.api);
            return;
          }
        }

        // pywebview 在，但 api 还没注入——继续等，最多 5 秒
        if (pywebviewSeen) {
          if (elapsed >= 5000) {
            clearInterval(timer);
            done(null);
          }
          return;
        }

        // 3. 纯浏览器：等 500ms 确认 pywebview 不会来
        if (elapsed >= 500) {
          clearInterval(timer);
          done(null);
        }
      }, 50);
    });
  }

  function bindGlobal() {
    var switcher = el("site-switcher-button");
    if (switcher) switcher.addEventListener("click", toggleSiteMenu);

    var addSite = el("menu-add-site");
    if (addSite) addSite.addEventListener("click", function () {
      closeSiteMenu();
      state.page = "sites";
      render();
      var input = el("add-site-input");
      if (input) input.focus();
    });

    var manageSites = el("menu-manage-sites");
    if (manageSites) manageSites.addEventListener("click", function () {
      closeSiteMenu();
      state.page = "sites";
      render();
    });

    document.addEventListener("mousedown", function (event) {
      var menu = el("site-menu");
      if (!menu || menu.hasAttribute("hidden")) return;
      if (menu.contains(event.target)) return;
      var button = el("site-switcher-button");
      if (button && button.contains(event.target)) return;
      closeSiteMenu();
    });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") closeSiteMenu();
      if ((event.metaKey || event.ctrlKey) && event.key === "s") {
        if (state.page === "posts" && state.selectedPostPath) {
          event.preventDefault();
          saveCurrentPost();
        }
      }
    });
  }

  function boot() {
    bindGlobal();

    waitForBackend().then(function (backend) {
      // 真实运行时把后端挂到 window.hexoman——这就是前端与后端之间的接口。
      // pywebview 自己注入的是 window.pywebview.api，这里包一层，
      // 前端代码就只认一个名字。
      if (backend) {
        window.hexoman = backend;
      }

      return api("getState");
    }).then(function (result) {
      if (!result || !result.ok) {
        // 纯浏览器预览（没有 pywebview）：用一份假数据把界面画出来
        state.strings = {};
        render();
        return;
      }

      state.language = result.language || "zh";
      state.languages = result.languages || [];
      state.strings = result.strings || {};
      state.sites = result.sites || [];
      state.currentSitePath = result.currentSitePath || "";
      state.siteInfo = result.siteInfo || null;
      state.serverPort = result.serverPort || 4000;
      state.serverRunning = !!result.serverRunning;
      state.platform = result.platform || "";
      state.previewDrafts = !!(result.settings && result.settings.previewDrafts);

      // 站点列表里的路径给一个短名字，切换器里显示得下
      state.sites.forEach(function (site) {
        site.name = site.path.split(/[\\/]/).filter(Boolean).pop() || site.path;
      });

      render();
      refreshOverview();
      if (state.currentSitePath) refreshPosts();
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }

  // 暴露给测试与调试
  window.HexoManUI = {
    state: state,
    render: render,
    countWords: countWords,
    filteredPosts: filteredPosts,
  };
})();
