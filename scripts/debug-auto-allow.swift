import AppKit
import ApplicationServices
import Foundation

enum Matchers {
  static let browserBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "org.chromium.Chromium",
  ]

  static let requiredTerms = [
    "remote debugging", "DevTools", "Developer Tools", "CDP", "chrome-devtools", "MCP",
    "remote debugging connection", "another program is trying",
    "远程调试", "遠端偵錯", "遠端調試",
  ]

  static let confirmationTerms = [
    "wants full control", "debug it", "saved data", "cookies and site data", "trusted apps",
    "external app", "navigate to any URL",
    "完全控制", "调试", "調試", "已保存的数据", "已儲存的資料", "可信的应用", "可信的應用",
  ]

  static let automationBannerTerms = [
    "Chrome is being controlled by automated test software",
    "Chrome 正受到自动测试软件的控制",
    "Chrome 目前受到自動測試軟體控制",
  ]

  static let allowButtonNames = ["Allow", "允许", "允許", "OK", "确定", "確定", "確認", "好"]
  static let denyButtonNames = ["Cancel", "取消", "Deny", "拒绝", "拒絕"]
  static let infobarNames = ["Infobar", "Info bar", "Infobar Container", "信息栏", "資訊欄", "資訊列"]
  static let dismissButtonNames = ["Close", "关闭", "關閉"]

  static let maximumTreeDepth = 9
  static let minimumActionInterval: TimeInterval = 3
}

final class AutoAllowApp: NSObject {
  private var dryRun = false
  private var focusSteal = false
  private var pollingInterval: TimeInterval = 0.4
  private var lastActionAt: Date = .distantPast

  func run(arguments: [String]) {
    if arguments.count >= 2, arguments[0] == "--match" {
      fputs(matchesDialogTerms(arguments[1]) ? "match\n" : "no-match\n", stdout)
      return
    }
    if arguments.count >= 2, arguments[0] == "--allow-button" {
      fputs(textIsOneOf(arguments[1], Matchers.allowButtonNames) ? "match\n" : "no-match\n", stdout)
      return
    }

    var runOnce = false
    var index = 0
    let args = arguments
    while index < args.count {
      let arg = args[index]
      if arg == "--dry-run" {
        dryRun = true
      } else if arg == "--allow-focus-steal" {
        focusSteal = true
      } else if arg == "--once" {
        runOnce = true
      } else if arg == "--interval", index + 1 < args.count {
        if let value = Double(args[index + 1]) {
          pollingInterval = min(5, max(0.2, value))
        }
        index += 1
      }
      index += 1
    }

    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    logMessage(
      "Started; dry-run=\(dryRun); focus-steal=\(focusSteal); interval=\(pollingInterval); ax-trusted=\(trusted)"
    )
    if !trusted {
      logMessage(
        "Accessibility permission is not granted for this app. Enable Debug Auto Allow in System Settings → Privacy & Security → Accessibility, then wait for the next scan (or relaunch)."
      )
    }
    if runOnce {
      scanBrowsers()
      return
    }

    let timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
      self?.scanBrowsers()
    }
    timer.tolerance = min(0.1, pollingInterval / 4)
    RunLoop.main.add(timer, forMode: .common)
    // First scan immediately so a just-granted permission takes effect without waiting.
    scanBrowsers()
    RunLoop.main.run()
  }

  private func scanBrowsers() {
    let apps = NSWorkspace.shared.runningApplications.filter { app in
      guard let bundleID = app.bundleIdentifier else { return false }
      return Matchers.browserBundleIDs.contains(bundleID)
    }

    for app in apps {
      let pid = app.processIdentifier
      let processName = app.localizedName ?? app.bundleIdentifier ?? "Chrome"
      let axApp = AXUIElementCreateApplication(pid)

      guard let windows = copyAttr(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
      for window in windows {
        let sheets = collectRole(window, role: "AXSheet", depth: 0, maxDepth: 2)
        if !sheets.isEmpty {
          for sheet in sheets {
            inspectContainer(sheet, pid: pid, processName: processName, kind: "sheet")
          }
        } else {
          inspectStandaloneWindow(window, pid: pid, processName: processName)
        }
        _ = inspectAutomationInfobar(window, pid: pid, processName: processName, depth: 0)
      }
    }
  }

  private func inspectStandaloneWindow(_ window: AXUIElement, pid: pid_t, processName: String) {
    let subrole = (copyAttr(window, kAXSubroleAttribute) as? String) ?? ""
    let title = (copyAttr(window, kAXTitleAttribute) as? String) ?? ""
    var width = 0
    var height = 0
    if let sizeValue = copyAttr(window, kAXSizeAttribute) {
      var size = CGSize.zero
      if AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
        width = Int(size.width)
        height = Int(size.height)
      }
    }

    let unnamed = title.isEmpty
    let smallUnknown =
      subrole.caseInsensitiveCompare("AXUnknown") == .orderedSame
      && width > 0 && height > 0 && width < 600 && height < 600

    if smallUnknown {
      inspectContainer(window, pid: pid, processName: processName, kind: "small-window")
    } else if unnamed {
      inspectContainer(window, pid: pid, processName: processName, kind: "unnamed-window")
    }
  }

  private func inspectContainer(
    _ container: AXUIElement, pid: pid_t, processName: String, kind: String
  ) {
    let dialogText = collectAccessibilityText(container, depth: 0)
    guard matchesDialogTerms(dialogText) else { return }

    let buttons = collectButtons(container, depth: 0)
    var allowButton: AXUIElement?
    var hasDeny = false
    for button in buttons {
      if allowButton == nil, matchingExactLabel(button, Matchers.allowButtonNames) != nil {
        allowButton = button
      }
      if matchingExactLabel(button, Matchers.denyButtonNames) != nil {
        hasDeny = true
      }
    }
    guard let allowButton else { return }
    if kind == "unnamed-window", !hasDeny { return }

    performApproval(allowButton, pid: pid, processName: processName, kind: kind)
  }

  @discardableResult
  private func inspectAutomationInfobar(
    _ element: AXUIElement, pid: pid_t, processName: String, depth: Int
  ) -> Bool {
    if depth > Matchers.maximumTreeDepth { return false }
    let role = (copyAttr(element, kAXRoleAttribute) as? String) ?? ""
    if role == "AXWebArea" || role == "AXDocument" { return false }

    if let infobarLabel = matchingExactLabel(element, Matchers.infobarNames) {
      let bannerText = collectAccessibilityText(element, depth: 0)
      let buttons = collectButtons(element, depth: 0)
      for button in buttons {
        if let dismissLabel = matchingExactLabel(button, Matchers.dismissButtonNames),
          matchesAutomationInfobar(
            marker: infobarLabel, bannerText: bannerText, buttonLabel: dismissLabel)
        {
          dismissAutomationBanner(button, pid: pid, processName: processName)
          return true
        }
      }
    }

    guard let children = copyAttr(element, kAXChildrenAttribute) as? [AXUIElement] else {
      return false
    }
    for child in children {
      if inspectAutomationInfobar(child, pid: pid, processName: processName, depth: depth + 1) {
        return true
      }
    }
    return false
  }

  private func performApproval(
    _ button: AXUIElement, pid: pid_t, processName: String, kind: String
  ) {
    guard canAct() else { return }
    markActed()

    if dryRun {
      logMessage("Matched \(kind) in \(processName); would click Allow (dry-run).")
      return
    }

    if press(button) {
      logMessage("Clicked Allow in \(processName) without activating Chrome.")
      return
    }

    if focusSteal {
      activate(pid: pid)
      if press(button) {
        logMessage("Clicked Allow in \(processName) after explicit focus-steal fallback.")
      } else {
        logMessage("Click failed in \(processName) after focus-steal fallback.")
      }
    } else {
      logMessage("Click failed in \(processName); retrying after cooldown.")
    }
  }

  private func dismissAutomationBanner(_ button: AXUIElement, pid: pid_t, processName: String) {
    guard canAct() else { return }
    markActed()

    if dryRun {
      logMessage(
        "Matched automation info bar in \(processName); would click its Close button (dry-run)."
      )
      return
    }

    if press(button) {
      logMessage("Dismissed automation info bar in \(processName) without activating Chrome.")
      return
    }

    if focusSteal {
      activate(pid: pid)
      if press(button) {
        logMessage(
          "Dismissed automation info bar in \(processName) after explicit focus-steal fallback."
        )
      } else {
        logMessage("Dismissal failed in \(processName) after focus-steal fallback.")
      }
    } else {
      logMessage("Dismissal failed in \(processName); retrying after cooldown.")
    }
  }

  private func canAct() -> Bool {
    Date().timeIntervalSince(lastActionAt) >= Matchers.minimumActionInterval
  }

  private func markActed() {
    lastActionAt = Date()
  }

  private func press(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
  }

  private func activate(pid: pid_t) {
    if let app = NSRunningApplication(processIdentifier: pid) {
      app.activate()
    }
  }

  private func collectRole(
    _ element: AXUIElement, role expectedRole: String, depth: Int, maxDepth: Int
  ) -> [AXUIElement] {
    if depth > maxDepth { return [] }
    var matches: [AXUIElement] = []
    let role = (copyAttr(element, kAXRoleAttribute) as? String) ?? ""
    if role == expectedRole {
      matches.append(element)
    }
    if let children = copyAttr(element, kAXChildrenAttribute) as? [AXUIElement] {
      for child in children {
        matches.append(
          contentsOf: collectRole(child, role: expectedRole, depth: depth + 1, maxDepth: maxDepth)
        )
      }
    }
    return matches
  }

  private func matchesDialogTerms(_ text: String) -> Bool {
    containsAny(text, Matchers.requiredTerms) && containsAny(text, Matchers.confirmationTerms)
  }

  private func matchesAutomationInfobar(marker: String, bannerText: String, buttonLabel: String)
    -> Bool
  {
    textIsOneOf(marker, Matchers.infobarNames)
      && containsAny(bannerText, Matchers.automationBannerTerms)
      && textIsOneOf(buttonLabel, Matchers.dismissButtonNames)
  }

  private func containsAny(_ text: String, _ terms: [String]) -> Bool {
    let haystack = text.lowercased()
    return terms.contains { haystack.contains($0.lowercased()) }
  }

  private func textIsOneOf(_ text: String, _ terms: [String]) -> Bool {
    terms.contains { text.caseInsensitiveCompare($0) == .orderedSame }
  }

  private func matchingExactLabel(_ element: AXUIElement, _ expected: [String]) -> String? {
    for label in elementLabels(element) {
      if textIsOneOf(label, expected) { return label }
    }
    return nil
  }

  private func elementLabels(_ element: AXUIElement) -> [String] {
    var labels: [String] = []
    if let title = copyAttr(element, kAXTitleAttribute) as? String, !title.isEmpty {
      labels.append(title)
    }
    if let description = copyAttr(element, kAXDescriptionAttribute) as? String, !description.isEmpty
    {
      labels.append(description)
    }
    if let value = copyAttr(element, kAXValueAttribute) as? String, !value.isEmpty {
      labels.append(value)
    }
    return labels
  }

  private func collectAccessibilityText(_ element: AXUIElement, depth: Int) -> String {
    if depth > Matchers.maximumTreeDepth { return "" }
    var parts: [String] = elementLabels(element)
    if let children = copyAttr(element, kAXChildrenAttribute) as? [AXUIElement] {
      for child in children {
        let childText = collectAccessibilityText(child, depth: depth + 1)
        if !childText.isEmpty { parts.append(childText) }
      }
    }
    return parts.joined(separator: " ")
  }

  private func collectButtons(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
    if depth > Matchers.maximumTreeDepth { return [] }
    var buttons: [AXUIElement] = []
    let role = (copyAttr(element, kAXRoleAttribute) as? String) ?? ""
    if role == "AXButton" {
      buttons.append(element)
    }
    if let children = copyAttr(element, kAXChildrenAttribute) as? [AXUIElement] {
      for child in children {
        buttons.append(contentsOf: collectButtons(child, depth: depth + 1))
      }
    }
    return buttons
  }

  private func copyAttr(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return result == .success ? value : nil
  }

  private func logMessage(_ message: String) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateStyle = .full
    formatter.timeStyle = .medium
    print("\(formatter.string(from: Date())) \(message)")
    fflush(stdout)
  }
}

let app = AutoAllowApp()
app.run(arguments: Array(CommandLine.arguments.dropFirst()))
