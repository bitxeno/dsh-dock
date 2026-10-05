import Foundation
import WebKit
import UserNotifications

/// 把浏览器 Notification / ServiceWorker 通知通道桥到 macOS 通知中心。
///
/// 为什么需要它：`WKWebView` 不实现 Web Notifications，也注册不了 Service Worker。
/// dsh-notify-me 这类纯浏览器层插件在壳里 `"Notification" in window === false`，
/// `canToast()` 恒 false —— 系统通知与「同意/拒绝」快捷裁决按钮整条链路失效，
/// 只剩提示音和标签页标题标记（设置页那句"通知权限尚未授予"也是同一根因）。
///
/// 桥的做法（不改动插件一行代码）：atDocumentStart 注入一层 shim，冒充
/// `Notification` 构造器与 `navigator.serviceWorker`，把 `new Notification()` /
/// `reg.showNotification()` 经 `webkit.messageHandlers.dshDockNotify` 转给
/// `UNUserNotificationCenter`；原生收到点击/按钮后再 `evaluateJavaScript` 回灌页面，
/// 走插件自己已挂好的 BroadcastChannel 监听（`onBridgeMessage` → `decidePending`
/// / `focusSession`），语义与浏览器端的 Service Worker 桥一致。
///
/// 权限：`Notification.permission` 反映真实 macOS 授权状态（启动即查一次并回灌
/// 页面），`requestPermission()` 触发原生授权弹窗，授权结果同样回灌——所以设置页
/// 那句提示会随真实状态消失/出现，不是写死 granted。
final class NotifyBridge: NSObject, WKScriptMessageHandler, UNUserNotificationCenterDelegate {

    static let shared = NotifyBridge()

    /// 注入页面的消息名（与 shim 里的 handlerName 对应）。
    static let messageName = "dshDockNotify"
    /// 带按钮通知的 category（macOS 通知按钮必须走预注册 category）。
    private static let approvalCategory = "dshDockNotify.approval"

    enum Permission: String {
        case granted
        case denied
        case `default`
    }

    private var webView: WKWebView?
    private var permission: Permission = .default
    /// tag -> 已投递的原生通知 identifier，用于同 tag 替换（renotify）与 close。
    private var tagToIds: [String: [String]] = [:]

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    // MARK: - 安装

    /// 尽早挂 delegate：晚了会漏掉 willPresent / didReceive 回调。
    func install() {
        center.delegate = self
        refreshPermission()
    }

    /// 后端切换后即时生效：notch 下不再读系统授权，直接报 granted；
    /// 切回 system 则重新查询真实状态。
    func backendDidChange() {
        refreshPermission()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        syncPermissionToPage()
    }

    /// 按需授权（Chrome 语义）：不在启动时主动弹窗，只有页面真的调用
    /// `Notification.requestPermission()` 才向 macOS 要权限。
    ///
    /// 时机由插件自己决定——dsh-notify-me 在页面第一次用户手势（pointerdown /
    /// keydown）或设置页点测试按钮时调 `requestPermission()`，所以"装了插件、
    /// 真的要用到通知"才弹窗。没装提醒插件的用户永远不会看到这个弹窗。
    ///
    /// 不缓存"已问过"标记：重复调用时若仍是 `notDetermined`（用户没理上次弹窗），
    /// 就再问一次；一旦用户做了决定，macOS 自己会记住、后续 `requestAuthorization`
    /// 直接回结果而不弹窗，不需要我们额外挡。
    private func requestAuthorization() {
        // notch-only：悬窗无需系统授权，直接视为 granted，永不弹窗。
        guard AppPreferences.notifyBackend.usesSystemCenter else {
            NSLog("[DshDock] 通知后端为刘海悬窗，跳过系统授权，直接 granted")
            setPermission(.granted)
            return
        }
        center.requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error { NSLog("[DshDock] 通知授权失败：\(error.localizedDescription)") }
                self?.setPermission(granted ? .granted : .denied)
                NSLog("[DshDock] 通知授权结果：granted=\(granted)")
            }
        }
    }

    private func refreshPermission() {
        // notch-only：不读系统状态（读出来默认是 notDetermined/denied，
        // 会让插件误判无权限），直接报 granted 让 canToast() 放行。
        guard AppPreferences.notifyBackend.usesSystemCenter else {
            NSLog("[DshDock] 通知后端为刘海悬窗，permission 直接 granted")
            DispatchQueue.main.async { [weak self] in self?.setPermission(.granted) }
            return
        }
        center.getNotificationSettings { [weak self] settings in
            let mapped = Self.map(status: settings.authorizationStatus)
            NSLog("[DshDock] 通知权限状态：raw=%d → %@ (alert=%d, badge=%d, sound=%d)",
                  settings.authorizationStatus.rawValue, mapped.rawValue,
                  settings.alertSetting.rawValue, settings.badgeSetting.rawValue,
                  settings.soundSetting.rawValue)
            DispatchQueue.main.async { self?.setPermission(mapped) }
        }
    }

    private static func map(status: UNAuthorizationStatus) -> Permission {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .default
        @unknown default: return .default
        }
    }

    private func setPermission(_ p: Permission) {
        permission = p
        syncPermissionToPage()
    }

    private func syncPermissionToPage() {
        guard let webView else { return }
        let js = "window.__dshDockNotify && window.__dshDockNotify._setPermission('\(permission.rawValue)')"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - WKScriptMessageHandler（页面 → 原生）

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let body = message.body as? [String: Any] else { return }
        guard let op = body["op"] as? String else { return }
        switch op {
        case "show":
            handleShow(body)
        case "close":
            if let id = body["id"] as? String {
                removeDelivered(identifiers: [id], tag: body["tag"] as? String)
                NotchToastManager.shared.dismiss(id: id)
                NotchToastManager.shared.dropParked(id: id)
            }
        case "request":
            requestAuthorization()
        case "query":
            // shim 每次文档启动都来问一次：原生单向回灌会落在尚未加载的页面上丢掉，
            // 拉模式才能保证插件读到的 permission 是真实 macOS 状态。
            refreshPermission()
        default:
            break
        }
    }

    private func handleShow(_ body: [String: Any]) {
        guard let id = body["id"] as? String else { return }
        let tag = body["tag"] as? String ?? ""
        let title = body["title"] as? String ?? ""
        let bodyText = body["body"] as? String ?? ""
        let actions = body["actions"] as? [[String: String]] ?? []
        let key = body["key"] as? String ?? ""
        let sessionId = body["sessionId"] as? String ?? ""
        let focus = (body["focus"] as? Bool) ?? true
        let backend = AppPreferences.notifyBackend

        // 同 tag 顶掉上一条：插件按 tag 复用一条通知（renotify）。
        if !tag.isEmpty, let olds = tagToIds[tag], !olds.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: olds)
            for old in olds { NotchToastManager.shared.dismiss(id: old) }
        }
        tagToIds[tag] = [id]

        let userInfo: [AnyHashable: Any] = [
            "id": id,
            "tag": tag,
            "key": key,
            "sessionId": sessionId,
            "focus": focus,
        ]

        if backend.usesNotch {
            let toastActions: [NotchToastAction] = actions.compactMap { item in
                guard let identifier = item["action"], !identifier.isEmpty else { return nil }
                return NotchToastAction(identifier: identifier, title: item["title"] ?? identifier)
            }
            // 刘海侧的点击语义与系统侧对齐：点正文抬窗 + 回灌空 action，
            // 点按钮只回灌不抬窗（插件语义：裁决不该把窗口拽上来）。
            NotchToastManager.shared.show(
                id: id, tag: tag, title: title, body: bodyText, actions: toastActions,
                onBodyClick: { [weak self] in
                    if focus { self?.raiseWindow() }
                    self?.removeDelivered(identifiers: [id], tag: tag.isEmpty ? nil : tag)
                    DispatchQueue.main.async { [weak self] in
                        self?.dispatchToPage(action: "", info: userInfo, navigate: focus)
                    }
                },
                onAction: { [weak self] identifier in
                    self?.removeDelivered(identifiers: [id], tag: tag.isEmpty ? nil : tag)
                    DispatchQueue.main.async { [weak self] in
                        self?.dispatchToPage(action: identifier, info: userInfo, navigate: focus)
                    }
                }
            )
        }

        guard backend.usesSystemCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = bodyText
        // 提示音由插件自己的 WebAudio 播（插件传了 silent:true），原生不要再叠一声。
        content.sound = nil
        content.userInfo = userInfo
        if !actions.isEmpty {
            registerApprovalCategory(actions: actions)
            content.categoryIdentifier = Self.approvalCategory
        } else {
            content.categoryIdentifier = ""
        }

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { error in
            if let error { NSLog("[DshDock] 投递通知失败：\(error.localizedDescription)") }
        }
    }

    /// macOS 的按钮必须挂在预注册的 category 上，且标题随插件语言变（同意/拒绝、
    /// Approve/Reject），所以每次带按钮的通知投递前按当前文案重注册一次。
    private func registerApprovalCategory(actions: [[String: String]]) {
        let unActions: [UNNotificationAction] = actions.compactMap { item in
            guard let identifier = item["action"], !identifier.isEmpty else { return nil }
            return UNNotificationAction(identifier: identifier,
                                        title: item["title"] ?? identifier,
                                        options: [])
        }
        guard !unActions.isEmpty else { return }
        let category = UNNotificationCategory(identifier: Self.approvalCategory,
                                              actions: unActions,
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
    }

    private func removeDelivered(identifiers: [String], tag: String?) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        guard let tag, let list = tagToIds[tag] else { return }
        let next = list.filter { !identifiers.contains($0) }
        if next.isEmpty { tagToIds.removeValue(forKey: tag) } else { tagToIds[tag] = next }
    }

    // MARK: - UNUserNotificationCenterDelegate（原生 → 页面）

    /// App 在前台时默认不显示横幅：必须显式放行，否则"页面打开着"时一条都看不到。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let raw = response.actionIdentifier
        let isBodyClick = raw == UNNotificationDefaultActionIdentifier
        let action = isBodyClick || raw == UNNotificationDismissActionIdentifier ? "" : raw
        let focus = (info["focus"] as? Bool) ?? true
        let tag = info["tag"] as? String ?? ""
        if let id = info["id"] as? String {
            removeDelivered(identifiers: [id], tag: tag.isEmpty ? nil : tag)
            NotchToastManager.shared.dismiss(id: id)
        }
        // 点正文 = "带我去那儿"，顺势把窗口抬到前台；点按钮不抬窗（插件语义：
        // 裁决不该把窗口拽上来）。autoFocus 关掉时插件传 focus:false，两边都不动。
        if isBodyClick && focus { raiseWindow() }
        DispatchQueue.main.async { [weak self] in
            self?.dispatchToPage(action: action, info: info, navigate: focus)
        }
        completionHandler()
    }

    private func raiseWindow() {
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
    }

    private func dispatchToPage(action: String, info: [AnyHashable: Any], navigate: Bool) {
        guard let webView else { return }
        let payload: [String: Any] = [
            "action": action,
            "key": (info["key"] as? String) ?? "",
            "sessionId": (info["sessionId"] as? String) ?? "",
            "navigate": navigate,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__dshDockNotify && window.__dshDockNotify._dispatch(\(json))") { _, error in
            if let error { NSLog("[DshDock] 通知点击回灌页面失败：\(error.localizedDescription)") }
        }
    }

    // MARK: - 注入脚本

    /// 冒充浏览器通知 API 的 shim。必须在 atDocumentStart 注入：插件在 apply()
    /// 里就读 `navigator.serviceWorker` 与 `Notification.permission`。
    static let shimSource = """
    (function () {
      if (window.__dshDockNotify) return;
      var SOURCE = "dsh-notify-me";
      var CHANNEL = "dsh-notify-me:bridge";
      var HANDLER = "dshDockNotify";
      var LS = "dshDockNotify.permission";
      // 权限跨页面加载保留：shim 在 atDocumentStart 跑，原生回灌要晚一拍，
      // 而插件在 apply()/测试按钮里同步读 Notification.permission —— 新文档
      // 起步就是 default 会让刷新后第一次点击静默失败。localStorage 同源常驻，
      // 正好当这个缓存（换端口即换 origin，自然失效）。
      var cached = "default";
      try {
        var saved = localStorage.getItem(LS);
        if (saved === "granted" || saved === "denied" || saved === "default") cached = saved;
      } catch (e) {}
      var state = { perm: cached, waiters: [] };
      var byTag = Object.create(null);
      var byKey = Object.create(null);
      var swListeners = [];
      var channel = null;

      function bridge() {
        try {
          if (!channel && typeof BroadcastChannel === "function") channel = new BroadcastChannel(CHANNEL);
        } catch (e) {}
        return channel;
      }
      function post(msg) {
        try {
          var h = window.webkit && window.webkit.messageHandlers;
          if (h && h[HANDLER]) h[HANDLER].postMessage(msg);
        } catch (e) {}
      }
      function newId() {
        return "n" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
      }
      function index(rec) {
        (byTag[rec.tag] = byTag[rec.tag] || []).push(rec);
        if (rec.key) (byKey[rec.key] = byKey[rec.key] || []).push(rec);
      }
      function unindex(rec) {
        function drop(map, k) {
          var list = map[k];
          if (!list) return;
          var next = [];
          for (var i = 0; i < list.length; i++) if (list[i] !== rec) next.push(list[i]);
          if (next.length) map[k] = next; else delete map[k];
        }
        drop(byTag, rec.tag);
        if (rec.key) drop(byKey, rec.key);
      }
      function show(rec) {
        index(rec);
        post({ op: "show", id: rec.id, tag: rec.tag, title: rec.title, body: rec.body,
               actions: rec.actions, key: rec.key, sessionId: rec.sessionId, focus: rec.focus });
      }
      function closeRec(rec) {
        if (!rec || rec.closed) return;
        rec.closed = true;
        post({ op: "close", id: rec.id, tag: rec.tag });
        unindex(rec);
      }
      function recFrom(title, options, isSW) {
        var o = options || {};
        var data = o.data || {};
        return {
          id: newId(),
          tag: o.tag || "",
          title: String(title),
          body: o.body || "",
          actions: o.actions || null,
          key: data.key || null,
          sessionId: data.sessionId || null,
          focus: data.focus !== false,
          sw: !!isSW,
          onclick: null, onclose: null, onshow: null, onerror: null,
          closed: false
        };
      }

      // ── Notification ──────────────────────────────────────────────
      function ShimNotification(title, options) {
        if (!(this instanceof ShimNotification)) return new ShimNotification(title, options);
        this._rec = recFrom(title, options, false);
        show(this._rec);
      }
      Object.defineProperty(ShimNotification, "permission", {
        get: function () { return state.perm; }
      });
      ShimNotification.maxActions = 2;
      ShimNotification.requestPermission = function (cb) {
        var p = new Promise(function (resolve) {
          state.waiters.push(resolve);
          post({ op: "request" });
          // 原生没回音（壳被换掉/消息通道缺失）时也要落地，否则 await 永远挂着。
          setTimeout(function () { flush(state.perm); }, 1500);
        });
        if (typeof cb === "function") p.then(function (v) { cb(v); }, function () { cb(state.perm); });
        return p;
      };
      ShimNotification.prototype.close = function () { closeRec(this._rec); };
      ["onclick", "onclose", "onshow", "onerror"].forEach(function (name) {
        Object.defineProperty(ShimNotification.prototype, name, {
          get: function () { return this._rec ? this._rec[name] : null; },
          set: function (fn) { if (this._rec) this._rec[name] = fn; }
        });
      });
      try {
        Object.defineProperty(window, "Notification", { value: ShimNotification, writable: true, configurable: true });
      } catch (e) {}

      // ── ServiceWorker（只够支撑通知按钮这一条链路）─────────────────
      function makeRegistration() {
        return {
          active: { state: "activated" },
          installing: null,
          waiting: null,
          scope: "/",
          showNotification: function (title, options) {
            show(recFrom(title, options, true));
            return Promise.resolve();
          },
          getNotifications: function (opts) {
            var tag = opts && opts.tag;
            var list = (tag && byTag[tag]) ? byTag[tag].slice() : [];
            return Promise.resolve(list.map(function (rec) {
              return { tag: rec.tag, body: rec.body, close: function () { closeRec(rec); } };
            }));
          },
          update: function () { return Promise.resolve(); },
          unregister: function () { return Promise.resolve(true); }
        };
      }
      var fakeSW = {
        controller: null,
        ready: Promise.resolve(makeRegistration()),
        register: function () { return Promise.resolve(makeRegistration()); },
        getRegistration: function () { return Promise.resolve(makeRegistration()); },
        getRegistrations: function () { return Promise.resolve([makeRegistration()]); },
        addEventListener: function (type, fn) { if (type === "message" && typeof fn === "function") swListeners.push(fn); },
        removeEventListener: function (type, fn) {
          var next = [];
          for (var i = 0; i < swListeners.length; i++) if (swListeners[i] !== fn) next.push(swListeners[i]);
          swListeners = next;
        }
      };
      try {
        Object.defineProperty(navigator, "serviceWorker", { value: fakeSW, configurable: true });
      } catch (e) {}
      // WKWebView 把 http://127.0.0.1 当安全上下文，个别宿主读出来却是 false，
      // 那会让插件直接判"不支持 Service Worker"而退回无按钮通知。
      try {
        if (window.isSecureContext !== true) {
          Object.defineProperty(window, "isSecureContext", { get: function () { return true; }, configurable: true });
        }
      } catch (e) {}

      function flush(value) {
        var w = state.waiters;
        state.waiters = [];
        for (var i = 0; i < w.length; i++) { try { w[i](value); } catch (e) {} }
      }

      // 主动向原生拉权限：原生单向回灌（_setPermission）在页面还没加载完时会被
      // evaluateJavaScript 丢掉，而插件在 apply()/测试按钮里同步读 permission，
      // 拿不到真值就会一直显示"通知权限尚未授予"。localStorage 只作首帧占位，
      // 真实状态一来就覆盖。
      post({ op: "query" });

      window.__dshDockNotify = {
        _setPermission: function (p) {
          if (p === "granted" || p === "denied" || p === "default") {
            state.perm = p;
            try { localStorage.setItem(LS, p); } catch (e) {}
            flush(p);
          }
          return state.perm;
        },
        // 原生点击/按钮回灌：优先走 BroadcastChannel，插件自己挂的监听会完成
        // 裁决（decidePending）与切会话（focusSession）；没有 BroadcastChannel
        // 时退到插件注册的 serviceworker message 监听，两条路都不通再调 onclick。
        _dispatch: function (msg) {
          msg = msg || {};
          var key = msg.key || null;
          var navigate = msg.navigate !== false;
          var payload = {
            source: SOURCE,
            type: "notification",
            action: msg.action || "",
            key: key,
            sessionId: msg.sessionId || null,
            navigate: navigate
          };
          var c = bridge();
          if (c) {
            try { c.postMessage(payload); } catch (e) {}
          } else if (swListeners.length) {
            for (var i = 0; i < swListeners.length; i++) {
              try { swListeners[i]({ data: payload }); } catch (e) {}
            }
          } else if (!payload.action && navigate) {
            var recs = key ? (byKey[key] || []).slice() : [];
            for (var j = 0; j < recs.length; j++) {
              var fn = recs[j].onclick;
              if (typeof fn === "function") { try { fn({ target: recs[j] }); } catch (e) {} }
            }
          }
          return true;
        },
        _state: function () {
          return { permission: state.perm, tags: Object.keys(byTag), keys: Object.keys(byKey) };
        }
      };
    })();
    """
}
