//  Copyright © MonitorControl. @victorchabbert, @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa

class OSDUtils: NSObject {
  enum OSDImage: Int64 {
    case brightness = 1
    case audioSpeaker = 3
    case audioSpeakerMuted = 4
    case contrast = 0
  }

  static func getOSDImageByCommand(command: Command, value: Float = 1) -> OSDImage {
    var osdImage: OSDImage
    switch command {
    case .audioSpeakerVolume: osdImage = value > 0 ? .audioSpeaker : .audioSpeakerMuted
    case .audioMuteScreenBlank: osdImage = .audioSpeakerMuted
    case .contrast: osdImage = .contrast
    default: osdImage = .brightness
    }
    return osdImage
  }

  // On macOS 26 (Tahoe) the private OSD framework still pops up its panel but no longer draws the level, so the user sees an
  // empty bezel (upstream issue #1782). A small in-app HUD in the style of the Tahoe bezel replaces it there.
  static var useCustomHUD: Bool {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
  }

  static func showOsd(displayID: CGDirectDisplayID, command: Command, value: Float, maxValue: Float = 1, roundChiclet: Bool = false, lock: Bool = false) {
    if self.useCustomHUD {
      let level = maxValue > 0 ? min(max(value / maxValue, 0), 1) : 0
      CustomHUD.shared.show(displayID: displayID, kind: CustomHUD.Kind(command: command, value: value), level: level)
      return
    }
    guard let manager = OSDManager.sharedManager() as? OSDManager else {
      return
    }
    let osdImage = self.getOSDImageByCommand(command: command, value: value)
    let filledChiclets: Int
    let totalChiclets: Int
    if roundChiclet {
      let osdChiclet = OSDUtils.chiclet(fromValue: value, maxValue: maxValue)
      filledChiclets = Int(round(osdChiclet))
      totalChiclets = 16
    } else {
      filledChiclets = Int(value * 100)
      totalChiclets = Int(maxValue * 100)
    }
    manager.showImage(osdImage.rawValue, onDisplayID: displayID, priority: 0x1F4, msecUntilFade: 1000, filledChiclets: UInt32(filledChiclets), totalChiclets: UInt32(totalChiclets), locked: lock)
  }

  static func showOsdVolumeDisabled(displayID: CGDirectDisplayID) {
    if self.useCustomHUD {
      CustomHUD.shared.show(displayID: displayID, kind: .unavailable, level: 0)
      return
    }
    guard let manager = OSDManager.sharedManager() as? OSDManager else {
      return
    }
    manager.showImage(22, onDisplayID: displayID, priority: 0x1F4, msecUntilFade: 1000)
  }

  static func showOsdMuteDisabled(displayID: CGDirectDisplayID) {
    if self.useCustomHUD {
      CustomHUD.shared.show(displayID: displayID, kind: .unavailable, level: 0)
      return
    }
    guard let manager = OSDManager.sharedManager() as? OSDManager else {
      return
    }
    manager.showImage(21, onDisplayID: displayID, priority: 0x1F4, msecUntilFade: 1000)
  }

  static func popEmptyOsd(displayID: CGDirectDisplayID, command: Command) {
    if self.useCustomHUD {
      CustomHUD.shared.show(displayID: displayID, kind: CustomHUD.Kind(command: command, value: 1), level: nil)
      return
    }
    guard let manager = OSDManager.sharedManager() as? OSDManager else {
      return
    }
    let osdImage = self.getOSDImageByCommand(command: command)
    manager.showImage(osdImage.rawValue, onDisplayID: displayID, priority: 0x1F4, msecUntilFade: 0)
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

// In-app replacement for the native on-screen display, used on macOS 26 and newer. A compact pill in the top right corner
// of the target display, below the menu bar, showing an icon and a level bar, fading out after a short while.
class CustomHUD {
  static let shared = CustomHUD()

  enum Kind {
    case brightness
    case contrast
    case volume
    case volumeMuted
    case unavailable

    init(command: Command, value: Float) {
      switch command {
      case .audioSpeakerVolume: self = value > 0 ? .volume : .volumeMuted
      case .audioMuteScreenBlank: self = .volumeMuted
      case .contrast: self = .contrast
      default: self = .brightness
      }
    }

    var symbolName: String {
      switch self {
      case .brightness: return "sun.max.fill"
      case .contrast: return "circle.lefthalf.filled"
      case .volume: return "speaker.wave.2.fill"
      case .volumeMuted: return "speaker.slash.fill"
      case .unavailable: return "speaker.slash.circle"
      }
    }
  }

  private let width: CGFloat = 236
  private let height: CGFloat = 44
  private let margin: CGFloat = 14
  private let visibleDuration: TimeInterval = 1.5

  private var windows: [CGDirectDisplayID: NSPanel] = [:]
  private var bars: [CGDirectDisplayID: (track: NSView, fill: NSView, icon: NSImageView)] = [:]
  private var fadeTimers: [CGDirectDisplayID: Timer] = [:]

  func show(displayID: CGDirectDisplayID, kind: Kind, level: Float?) {
    if !Thread.isMainThread {
      DispatchQueue.main.async {
        self.show(displayID: displayID, kind: kind, level: level)
      }
      return
    }
    let effectiveDisplayID = DisplayManager.resolveEffectiveDisplayID(displayID)
    guard let screen = NSScreen.screens.first(where: { $0.displayID == effectiveDisplayID }) ?? NSScreen.main else {
      return
    }
    let window = self.windows[effectiveDisplayID] ?? self.makeWindow(displayID: effectiveDisplayID)
    self.update(displayID: effectiveDisplayID, kind: kind, level: level)
    let frame = screen.visibleFrame
    window.setFrameOrigin(NSPoint(x: frame.maxX - self.width - self.margin, y: frame.maxY - self.height - self.margin))
    self.fadeTimers[effectiveDisplayID]?.invalidate()
    window.alphaValue = 1
    window.orderFrontRegardless()
    let timer = Timer(timeInterval: self.visibleDuration, repeats: false) { [weak self, weak window] _ in
      guard let window = window else {
        return
      }
      self?.fadeOut(window)
    }
    RunLoop.main.add(timer, forMode: .common)
    self.fadeTimers[effectiveDisplayID] = timer
  }

  private func fadeOut(_ window: NSWindow) {
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.35
      window.animator().alphaValue = 0
    }, completionHandler: {
      if window.alphaValue == 0 {
        window.orderOut(nil)
      }
    })
  }

  private func makeWindow(displayID: CGDirectDisplayID) -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: self.width, height: self.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .screenSaver
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.animationBehavior = .none

    let root = NSView(frame: NSRect(x: 0, y: 0, width: self.width, height: self.height))
    root.wantsLayer = true
    let blur = NSVisualEffectView(frame: root.bounds)
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.wantsLayer = true
    blur.layer?.cornerRadius = self.height / 2
    blur.layer?.masksToBounds = true
    blur.layer?.borderWidth = 0.5
    blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
    root.addSubview(blur)

    let iconSize: CGFloat = 20
    let icon = NSImageView(frame: NSRect(x: 16, y: (self.height - iconSize) / 2, width: iconSize, height: iconSize))
    icon.imageScaling = .scaleProportionallyUpOrDown
    if #available(macOS 11.0, *) {
      icon.contentTintColor = .labelColor
    }
    blur.addSubview(icon)

    let barX: CGFloat = 16 + iconSize + 14
    let barHeight: CGFloat = 8
    let track = NSView(frame: NSRect(x: barX, y: (self.height - barHeight) / 2, width: self.width - barX - 18, height: barHeight))
    track.wantsLayer = true
    track.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
    track.layer?.cornerRadius = barHeight / 2
    blur.addSubview(track)

    let fill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: barHeight))
    fill.wantsLayer = true
    fill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.9).cgColor
    fill.layer?.cornerRadius = barHeight / 2
    track.addSubview(fill)

    panel.contentView = root
    self.windows[displayID] = panel
    self.bars[displayID] = (track, fill, icon)
    return panel
  }

  private func update(displayID: CGDirectDisplayID, kind: Kind, level: Float?) {
    guard let parts = self.bars[displayID] else {
      return
    }
    if #available(macOS 11.0, *) {
      let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
      parts.icon.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
    let dimmed = kind == .volumeMuted || kind == .unavailable
    parts.icon.alphaValue = dimmed ? 0.5 : 1
    let width = parts.track.bounds.width * CGFloat(dimmed ? 0 : (level ?? 0))
    parts.fill.frame = NSRect(x: 0, y: 0, width: width, height: parts.track.bounds.height)
    parts.track.isHidden = level == nil
  }
}
