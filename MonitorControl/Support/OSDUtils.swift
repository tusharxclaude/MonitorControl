//  Copyright © MonitorControl. @victorchabbert, @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa

class OSDUtils: NSObject {
  enum OSDImage: Int64 {
    case brightness = 1
    case audioSpeaker = 3
    case audioSpeakerMuted = 4
    case contrast = 11
  }

  static func getOSDImageByCommand(command: Command, value: Float = 1) -> OSDImage {
    var osdImage: OSDImage
    switch command {
    case .audioSpeakerVolume:
      osdImage = value > 0 ? .audioSpeaker : .audioSpeakerMuted
    case .audioMuteScreenBlank:
      osdImage = .audioSpeakerMuted
    case .contrast:
      osdImage = .contrast
    default:
      osdImage = .brightness
    }
    return osdImage
  }

  static func showOsd(displayID: CGDirectDisplayID, command: Command, value: Float, maxValue: Float = 1, roundChiclet: Bool = false, lock: Bool = false) {
    let safeMax = max(maxValue, 0.0001)
    let normalized: Float
    if roundChiclet {
      let chiclet = self.chiclet(fromValue: value, maxValue: safeMax).rounded()
      normalized = max(0, min(1, chiclet / self.chicletCount))
    } else {
      normalized = max(0, min(1, value / safeMax))
    }

    guard !DEBUG_MACOS10, #available(macOS 26.0, *) else {
      self.withLegacyOSD { manager in
        let osdImage = self.getOSDImageByCommand(command: command, value: value)
        let filledChiclets: Int
        let totalChiclets: Int
        if roundChiclet {
          let chiclet = self.chiclet(fromValue: value, maxValue: safeMax)
          filledChiclets = Int(chiclet.rounded())
          totalChiclets = Int(self.chicletCount)
        } else {
          filledChiclets = Int(value * 100)
          totalChiclets = Int(safeMax * 100)
        }
        manager.showImage(
          osdImage.rawValue,
          onDisplayID: displayID,
          priority: 0x1F4,
          msecUntilFade: 1000,
          filledChiclets: UInt32(filledChiclets),
          totalChiclets: UInt32(totalChiclets),
          locked: lock
        )
      }
      return
    }

    MacOS27OSDHudController.shared.show(displayID: displayID, command: command, normalizedValue: normalized, locked: lock)
  }

  static func showOsdVolumeDisabled(displayID: CGDirectDisplayID) {
    guard !DEBUG_MACOS10, #available(macOS 26.0, *) else {
      self.withLegacyOSD { manager in
        manager.showImage(22, onDisplayID: displayID, priority: 0x1F4, msecUntilFade: 1000)
      }
      return
    }
    MacOS27OSDHudController.shared.show(displayID: displayID, command: .audioSpeakerVolume, normalizedValue: 0, locked: true)
  }

  static func showOsdMuteDisabled(displayID: CGDirectDisplayID) {
    guard !DEBUG_MACOS10, #available(macOS 26.0, *) else {
      self.withLegacyOSD { manager in
        manager.showImage(21, onDisplayID: displayID, priority: 0x1F4, msecUntilFade: 1000)
      }
      return
    }
    MacOS27OSDHudController.shared.show(displayID: displayID, command: .audioMuteScreenBlank, normalizedValue: 0, locked: true)
  }

  static func popEmptyOsd(displayID: CGDirectDisplayID, command: Command) {
    guard !DEBUG_MACOS10, #available(macOS 26.0, *) else {
      self.withLegacyOSD { manager in
        let osdImage = self.getOSDImageByCommand(command: command)
        manager.showImage(osdImage.rawValue, onDisplayID: displayID, priority: 0x1F4, msecUntilFade: 0)
      }
      return
    }
  }

  private static func withLegacyOSD(_ show: @escaping (OSDUIHelperProtocol) -> Void) {
    if let manager = OSDManager.sharedManager() as? OSDManager {
      show(manager)
    }
  }

  static let chicletCount: Float = 16

  static func chiclet(fromValue value: Float, maxValue: Float, half: Bool = false) -> Float {
    (value * self.chicletCount * (half ? 2 : 1)) / maxValue
  }

  static func value(fromChiclet chiclet: Float, maxValue: Float, half: Bool = false) -> Float {
    (chiclet * maxValue) / (self.chicletCount * (half ? 2 : 1))
  }

  static func getDistance(fromNearestChiclet chiclet: Float) -> Float {
    abs(chiclet.rounded(.towardZero) - chiclet)
  }
}

@available(macOS 26.0, *)
final class MacOS27OSDHudController {
  static let shared = MacOS27OSDHudController()

  private var panels: [CGDirectDisplayID: OSDHudPanel] = [:]
  private var hideWorkItems: [CGDirectDisplayID: DispatchWorkItem] = [:]

  func show(displayID: CGDirectDisplayID, command: Command, normalizedValue: Float, locked: Bool = false) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        self.show(displayID: displayID, command: command, normalizedValue: normalizedValue, locked: locked)
      }
      return
    }
    let effectiveDisplayID = DisplayManager.resolveEffectiveDisplayID(displayID)
    guard let targetScreen = self.resolveScreen(for: effectiveDisplayID) else { return }
    let display = self.resolveDisplay(displayID: displayID, effectiveDisplayID: effectiveDisplayID)
    let displayName = self.resolveDisplayName(display: display, effectiveDisplayID: effectiveDisplayID)
    let badgeText = self.resolveBadgeText(display: display, command: command, normalizedValue: normalizedValue, locked: locked)
    let panel = self.panel(for: effectiveDisplayID)

    panel.hudView.update(
      title: displayName,
      badgeText: badgeText,
      command: command,
      value: normalizedValue,
      locked: locked
    )
    panel.position(on: targetScreen)
    self.presentPanel(panel)
    self.scheduleHide(for: effectiveDisplayID, panel: panel)
  }

  private func resolveDisplay(displayID: CGDirectDisplayID, effectiveDisplayID: CGDirectDisplayID) -> Display? {
    DisplayManager.shared.displays.first { $0.identifier == displayID }
      ?? DisplayManager.shared.displays.first { DisplayManager.resolveEffectiveDisplayID($0.identifier) == effectiveDisplayID }
  }

  private func resolveScreen(for effectiveDisplayID: CGDirectDisplayID) -> NSScreen? {
    DisplayManager.getByDisplayID(displayID: effectiveDisplayID) ?? NSScreen.main ?? NSScreen.screens.first
  }

  private func resolveDisplayName(display: Display?, effectiveDisplayID: CGDirectDisplayID) -> String {
    if let display = display {
      return display.getFriendlyName()
    }
    if CGDisplayIsBuiltin(effectiveDisplayID) != 0 {
      return NSLocalizedString("Built-in Display", comment: "Built-in display name")
    }
    return DisplayManager.getDisplayNameByID(displayID: effectiveDisplayID)
  }

  private func resolveBadgeText(display: Display?, command: Command, normalizedValue: Float, locked: Bool) -> String {
    if locked {
      return NSLocalizedString("Locked", comment: "Shown in OSD pill badge when control is disabled")
    }
    if command == .audioMuteScreenBlank || (command == .audioSpeakerVolume && normalizedValue <= 0.001) {
      return "0%"
    }
    let pct = Int((normalizedValue * 100).rounded())
    if command == .brightness, let nits = display?.getNits(forValue: normalizedValue) {
      return "\(pct)% • \(nits) nits"
    }
    return "\(pct)%"
  }

  private func panel(for effectiveDisplayID: CGDirectDisplayID) -> OSDHudPanel {
    if let existingPanel = self.panels[effectiveDisplayID] {
      return existingPanel
    }
    let panel = OSDHudPanel()
    self.panels[effectiveDisplayID] = panel
    return panel
  }

  private func presentPanel(_ panel: OSDHudPanel) {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if !panel.isVisible || panel.alphaValue < 0.99 {
      if !panel.isVisible {
        panel.alphaValue = reduceMotion ? 1.0 : 0.0
        panel.orderFrontRegardless()
      }
      if reduceMotion {
        panel.alphaValue = 1.0
      } else {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.14
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          panel.animator().alphaValue = 1.0
        }
      }
    } else {
      panel.orderFrontRegardless()
    }
  }

  private func scheduleHide(for effectiveDisplayID: CGDirectDisplayID, panel: OSDHudPanel) {
    self.hideWorkItems[effectiveDisplayID]?.cancel()
    let workItem = DispatchWorkItem { [weak self, weak panel] in
      guard let panel = panel else { return }
      let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      if reduceMotion {
        panel.alphaValue = 0.0
        panel.orderOut(nil)
      } else {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.25
          context.timingFunction = CAMediaTimingFunction(name: .easeIn)
          panel.animator().alphaValue = 0.0
        } completionHandler: {
          if panel.alphaValue == 0.0 {
            panel.orderOut(nil)
          }
        }
      }
      self?.hideWorkItems[effectiveDisplayID] = nil
    }
    self.hideWorkItems[effectiveDisplayID] = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: workItem)
  }
}

@available(macOS 26.0, *)
final class OSDHudPanel: NSPanel {
  static let hudWidth: CGFloat = 292
  static let hudHeight: CGFloat = 64

  let hudView = MacOS27OSDHudView(frame: NSRect(x: 0, y: 0, width: OSDHudPanel.hudWidth, height: OSDHudPanel.hudHeight))

  override var canBecomeKey: Bool {
    true
  }

  @objc func hasKeyAppearance() -> Bool {
    true
  }

  @objc func _hasActiveAppearance() -> Bool {
    true
  }

  @objc func _hasActiveControls() -> Bool {
    true
  }

  init() {
    let rect = NSRect(x: 0, y: 0, width: Self.hudWidth, height: Self.hudHeight)
    super.init(
      contentRect: rect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    self.isFloatingPanel = true
    self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
    self.backgroundColor = .clear
    self.isOpaque = false
    self.hasShadow = false
    self.isMovable = false
    self.ignoresMouseEvents = true
    self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    self.contentView = self.hudView
  }

  func position(on screen: NSScreen) {
    let screenFrame = screen.frame
    let visibleFrame = screen.visibleFrame
    let panelSize = self.frame.size
    let originX = screenFrame.midX - (panelSize.width / 2.0)
    let menuBarInset = max(screenFrame.maxY - visibleFrame.maxY, 26.0)
    let topMargin: CGFloat = 14.0
    let originY = screenFrame.maxY - menuBarInset - topMargin - panelSize.height
    self.setFrameOrigin(NSPoint(x: round(originX), y: round(originY)))
  }
}

@available(macOS 26.0, *)
final class MacOS27OSDHudView: NSView {
  private let containerView = NSView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let badgeContainer = NSView()
  private let badgeLabel = NSTextField(labelWithString: "")
  private let minIconView = NSImageView()
  private let maxIconView = NSImageView()
  private let trackBarView = MacOS27TrackBarView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    self.setupViews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    self.setupViews()
  }

  private func setupViews() {
    self.wantsLayer = true

    let glassView = NSGlassEffectView(frame: self.bounds)
    glassView.autoresizingMask = [.width, .height]
    glassView.cornerRadius = 19.5
    glassView.style = .regular
    self.addSubview(glassView)
    self.containerView.frame = glassView.bounds
    self.containerView.autoresizingMask = [.width, .height]
    glassView.contentView = self.containerView
    let rootContent = self.containerView

    self.titleLabel.font = NSFont.systemFont(ofSize: 13.0, weight: .semibold)
    self.titleLabel.lineBreakMode = .byTruncatingTail
    self.titleLabel.maximumNumberOfLines = 1

    self.badgeContainer.wantsLayer = true
    self.badgeContainer.layer?.cornerRadius = 8.0
    self.badgeContainer.layer?.cornerCurve = .continuous

    self.badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    self.badgeLabel.alignment = .center
    self.badgeLabel.maximumNumberOfLines = 1
    self.badgeContainer.addSubview(self.badgeLabel)

    self.minIconView.imageScaling = .scaleProportionallyDown
    self.maxIconView.imageScaling = .scaleProportionallyDown

    self.trackBarView.setAccessibilityElement(true)
    self.trackBarView.setAccessibilityRole(.levelIndicator)

    rootContent.addSubview(self.titleLabel)
    rootContent.addSubview(self.badgeContainer)
    rootContent.addSubview(self.minIconView)
    rootContent.addSubview(self.trackBarView)
    rootContent.addSubview(self.maxIconView)

    self.applyAppearanceColors()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.applyAppearanceColors()
  }

  private func applyAppearanceColors() {
    let isDark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let fgColor = isDark ? NSColor(calibratedWhite: 1.0, alpha: 0.96) : NSColor(calibratedWhite: 0.06, alpha: 0.92)
    let badgeBgColor = isDark ? NSColor(calibratedWhite: 0.96, alpha: 0.88) : NSColor(calibratedWhite: 0.08, alpha: 0.82)
    let badgeFgColor = isDark ? NSColor(calibratedWhite: 0.12, alpha: 0.96) : NSColor(calibratedWhite: 0.98, alpha: 0.96)

    self.titleLabel.textColor = fgColor
    self.minIconView.contentTintColor = fgColor
    self.maxIconView.contentTintColor = fgColor
    self.badgeContainer.layer?.backgroundColor = badgeBgColor.cgColor
    self.badgeLabel.textColor = badgeFgColor
    self.trackBarView.needsDisplay = true
  }

  override func layout() {
    super.layout()
    let bounds = self.bounds

    let badgeSize = self.badgeLabel.fittingSize
    let badgePadX: CGFloat = 8.0
    let badgeWidth = ceil(badgeSize.width) + badgePadX * 2
    let badgeHeight: CGFloat = 16.0

    let titleSize = self.titleLabel.fittingSize
    let maxTitleWidth = max(60, bounds.width - 36.0 - badgeWidth - 8.0)
    let titleWidth = min(ceil(titleSize.width), maxTitleWidth)
    let titleHeight = ceil(titleSize.height)

    let headerY: CGFloat = 38.0
    self.titleLabel.frame = NSRect(x: 18.0, y: headerY, width: titleWidth, height: titleHeight)

    let badgeX = self.titleLabel.frame.maxX + 8.0
    let badgeY = headerY + round((titleHeight - badgeHeight) / 2.0)
    self.badgeContainer.frame = NSRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight)
    self.badgeLabel.frame = NSRect(
      x: badgePadX,
      y: round((badgeHeight - ceil(badgeSize.height)) / 2.0),
      width: ceil(badgeSize.width),
      height: ceil(badgeSize.height)
    )

    let iconSize: CGFloat = 16.0
    let sliderCenterY: CGFloat = 24.0
    self.minIconView.frame = NSRect(x: 15.0, y: round(sliderCenterY - iconSize / 2.0), width: iconSize, height: iconSize)
    self.maxIconView.frame = NSRect(x: bounds.width - 15.0 - iconSize, y: round(sliderCenterY - iconSize / 2.0), width: iconSize, height: iconSize)

    let trackX: CGFloat = 35.0
    let trackWidth = bounds.width - 70.0
    self.trackBarView.frame = NSRect(x: trackX, y: 12.0, width: trackWidth, height: 18.0)
  }

  func update(title: String, badgeText: String, command: Command, value: Float, locked: Bool) {
    self.titleLabel.stringValue = title
    self.badgeLabel.stringValue = badgeText
    let icons = self.resolveSymbols(for: command, value: value)
    let minCfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
    let maxCfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)
    self.minIconView.image = NSImage(systemSymbolName: icons.min, accessibilityDescription: nil)?.withSymbolConfiguration(minCfg)
    self.maxIconView.image = NSImage(systemSymbolName: icons.max, accessibilityDescription: nil)?.withSymbolConfiguration(maxCfg)
    self.trackBarView.progress = CGFloat(max(0, min(1, value)))
    self.trackBarView.isLocked = locked
    self.trackBarView.setAccessibilityLabel(title)
    self.trackBarView.setAccessibilityValue(badgeText)
    self.applyAppearanceColors()
    self.needsLayout = true
    self.layoutSubtreeIfNeeded()
  }

  private func resolveSymbols(for command: Command, value: Float) -> (min: String, max: String) {
    switch command {
    case .audioSpeakerVolume, .audioMuteScreenBlank:
      let minSymbol = (command == .audioMuteScreenBlank || value <= 0.001) ? "speaker.slash.fill" : "speaker.fill"
      return (minSymbol, "speaker.wave.3.fill")
    case .contrast:
      return ("circle.lefthalf.filled", "circle.righthalf.filled")
    default:
      return ("sun.min.fill", "sun.max.fill")
    }
  }
}

@available(macOS 26.0, *)
final class MacOS27TrackBarView: NSView {
  var progress: CGFloat = 0 {
    didSet {
      self.needsDisplay = true
    }
  }

  var isLocked: Bool = false {
    didSet {
      self.needsDisplay = true
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let bounds = self.bounds
    let isDark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let baseWhite: CGFloat = isDark ? 1.0 : 0.06
    let trackAlpha: CGFloat = isDark ? 0.24 : 0.20
    let fillAlpha: CGFloat = isDark ? 0.98 : 0.90
    let dotAlpha: CGFloat = isDark ? 0.28 : 0.25

    let trackHeight: CGFloat = 4.0
    let trackY: CGFloat = 10.0
    let trackRect = NSRect(x: 0, y: trackY, width: bounds.width, height: trackHeight)

    let bgPath = NSBezierPath(roundedRect: trackRect, xRadius: trackHeight / 2.0, yRadius: trackHeight / 2.0)
    NSColor(calibratedWhite: baseWhite, alpha: trackAlpha).setFill()
    bgPath.fill()

    let clamped = max(0, min(1, self.progress))
    if clamped > 0.002, !self.isLocked {
      let fillWidth = max(trackHeight, round(bounds.width * clamped))
      let fillRect = NSRect(x: 0, y: trackY, width: fillWidth, height: trackHeight)
      let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackHeight / 2.0, yRadius: trackHeight / 2.0)
      NSColor(calibratedWhite: baseWhite, alpha: fillAlpha).setFill()
      fillPath.fill()
    }

    let dotCount = 16
    let dotSize: CGFloat = 2.0
    let dotY: CGFloat = 4.5
    let insetX: CGFloat = 16.25
    let usableWidth = max(1, bounds.width - insetX * 2)
    let step = usableWidth / CGFloat(dotCount - 1)
    NSColor(calibratedWhite: baseWhite, alpha: dotAlpha).setFill()
    for index in 0 ..< dotCount {
      let dotX = insetX + CGFloat(index) * step - (dotSize / 2.0)
      let dotRect = NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
      let dotPath = NSBezierPath(ovalIn: dotRect)
      dotPath.fill()
    }
  }
}
