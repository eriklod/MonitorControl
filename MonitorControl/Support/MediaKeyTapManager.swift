//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import AudioToolbox
import Cocoa
import Foundation
import MediaKeyTap
import os.log

class MediaKeyTapManager: MediaKeyTapDelegate {
  var mediaKeyTap: MediaKeyTap?
  var keyRepeatTimers: [MediaKey: Timer] = [:]
  var lastMediaKeyEventTime: CFTimeInterval = 0 // used by the tap watchdog to avoid re-registering the tap while keys are in use
  var watchedKeys: [MediaKey] = [] // the keys the current tap was started with

  func handle(mediaKey: MediaKey, event: KeyEvent?, modifiers: NSEvent.ModifierFlags?) {
    let isPressed = event?.keyPressed ?? true
    let isRepeat = event?.keyRepeat ?? false
    self.lastMediaKeyEventTime = CACurrentMediaTime()
    if isPressed, !isRepeat {
      // Logged at default level on purpose: info level messages are not persisted on recent macOS versions, and this line
      // is what tells us whether a key press reached the app at all when a user reports "the keys do nothing".
      os_log("Media key %{public}@ received (sleepID %{public}@, reconfigureID %{public}@)", type: .default, String(describing: mediaKey), String(app.sleepID), String(app.reconfigureID))
    }
    let isControl = modifiers?.isSuperset(of: NSEvent.ModifierFlags([.control])) ?? false
    let isCommand = modifiers?.isSuperset(of: NSEvent.ModifierFlags([.command])) ?? false
    let isOption = modifiers?.isSuperset(of: NSEvent.ModifierFlags([.option])) ?? false
    let isShift = modifiers?.isSuperset(of: NSEvent.ModifierFlags([.shift])) ?? false
    if isPressed, isCommand, !isControl, mediaKey == .brightnessDown, DisplayManager.engageMirror() {
      return
    }
    guard app.sleepID == 0, app.reconfigureID == 0 else {
      return
    }
    if isPressed, self.handleOpenPrefPane(mediaKey: mediaKey, event: event, modifiers: modifiers) {
      return
    }
    var isSmallIncrement = isOption && isShift
    let isContrast = isControl && isOption && isCommand
    if [.brightnessUp, .brightnessDown].contains(mediaKey), prefs.bool(forKey: PrefKey.useFineScaleBrightness.rawValue) {
      isSmallIncrement = !isSmallIncrement
    }
    if [.volumeUp, .volumeDown, .mute].contains(mediaKey), prefs.bool(forKey: PrefKey.useFineScaleVolume.rawValue) {
      isSmallIncrement = !isSmallIncrement
    }
    if isPressed, isControl, !isOption, mediaKey == .brightnessUp || mediaKey == .brightnessDown {
      self.handleDirectedBrightness(isCommandModifier: isCommand, isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
      return
    }
    let oppositeKey: MediaKey? = self.oppositeMediaKey(mediaKey: mediaKey)
    // If the opposite key to the one being held has an active timer, cancel it - we'll be going in the opposite direction
    if let oppositeKey = oppositeKey, let oppositeKeyTimer = self.keyRepeatTimers[oppositeKey], oppositeKeyTimer.isValid {
      oppositeKeyTimer.invalidate()
    } else if let mediaKeyTimer = self.keyRepeatTimers[mediaKey], mediaKeyTimer.isValid {
      // If there's already an active timer for the key being held down, let it run rather than executing it again
      if isRepeat {
        return
      }
      mediaKeyTimer.invalidate()
    }
    self.sendDisplayCommand(mediaKey: mediaKey, isRepeat: isRepeat, isSmallIncrement: isSmallIncrement, isPressed: isPressed, isContrast: isContrast)
  }

  func handleDirectedBrightness(isCommandModifier: Bool, isUp: Bool, isSmallIncrement: Bool) {
    if isCommandModifier {
      for otherDisplay in DisplayManager.shared.getOtherDisplays() {
        otherDisplay.stepBrightness(isUp: isUp, isSmallIncrement: isSmallIncrement)
      }
      for appleDisplay in DisplayManager.shared.getAppleDisplays() where !appleDisplay.isBuiltIn() {
        appleDisplay.stepBrightness(isUp: isUp, isSmallIncrement: isSmallIncrement)
      }
      return
    } else if let internalDisplay = DisplayManager.shared.getBuiltInDisplay() as? AppleDisplay {
      internalDisplay.stepBrightness(isUp: isUp, isSmallIncrement: isSmallIncrement)
      return
    }
  }

  private func sendDisplayCommand(mediaKey: MediaKey, isRepeat: Bool, isSmallIncrement: Bool, isPressed: Bool, isContrast: Bool = false) {
    self.sendDisplayCommandVolumeMute(mediaKey: mediaKey, isRepeat: isRepeat, isSmallIncrement: isSmallIncrement, isPressed: isPressed)
    self.sendDisplayCommandBrightnessContrast(mediaKey: mediaKey, isRepeat: isRepeat, isSmallIncrement: isSmallIncrement, isPressed: isPressed, isContrast: isContrast)
  }

  // The display under the mouse pointer cannot always be determined (pointer exactly on an edge, stale screen list right
  // after a reconfiguration, no key window in focus mode). A key press must never silently do nothing in that case, so
  // fall back to the external displays, and only if there are none, to the built-in display.
  private func fallbackDisplays(isBrightness: Bool) -> [Display] {
    let externalDisplays = DisplayManager.shared.getAllDisplays().filter { !$0.isBuiltIn() && !$0.isDummy && !$0.isVirtual }
    if !externalDisplays.isEmpty {
      return externalDisplays
    }
    if isBrightness, let builtIn = DisplayManager.shared.getBuiltInDisplay() {
      return [builtIn]
    }
    return []
  }

  private func affectedDisplays(isBrightness: Bool, isVolume: Bool) -> [Display] {
    if let affectedDisplays = DisplayManager.shared.getAffectedDisplays(isBrightness: isBrightness, isVolume: isVolume), !affectedDisplays.isEmpty {
      return affectedDisplays
    }
    if isVolume, prefs.integer(forKey: PrefKey.multiKeyboardVolume.rawValue) == MultiKeyboardVolume.audioDeviceNameMatching.rawValue {
      return [] // no display matches the audio device by name, this is intentional
    }
    let fallback = self.fallbackDisplays(isBrightness: isBrightness)
    os_log("No target display found for %{public}@ key (mouse at %{public}@), falling back to %{public}@ display(s)", type: .default, isBrightness ? "brightness" : "volume", NSStringFromPoint(NSEvent.mouseLocation), String(fallback.count))
    return fallback
  }

  private func sendDisplayCommandVolumeMute(mediaKey: MediaKey, isRepeat: Bool, isSmallIncrement: Bool, isPressed: Bool) {
    guard [.volumeUp, .volumeDown, .mute].contains(mediaKey), app.sleepID == 0, app.reconfigureID == 0 else {
      return
    }
    let affectedDisplays = self.affectedDisplays(isBrightness: false, isVolume: true)
    var wasNotIsPressedVolumeSentAlready = false
    for display in affectedDisplays where !display.readPrefAsBool(key: .isDisabled) {
      switch mediaKey {
      case .mute:
        // The mute key should not respond to press + hold or keyup
        if !isRepeat, isPressed, let display = display as? OtherDisplay {
          display.toggleMute()
          if !wasNotIsPressedVolumeSentAlready, display.readPrefAsInt(for: .audioMuteScreenBlank) != 1, !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume) {
            app.playVolumeChangedSound()
            wasNotIsPressedVolumeSentAlready = true
          }
        }
      case .volumeUp, .volumeDown:
        // volume only matters for other displays
        if let display = display as? OtherDisplay {
          if isPressed {
            display.stepVolume(isUp: mediaKey == .volumeUp, isSmallIncrement: isSmallIncrement)
          } else if !wasNotIsPressedVolumeSentAlready, !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume) {
            app.playVolumeChangedSound()
            wasNotIsPressedVolumeSentAlready = true
          }
        }
      default: continue
      }
    }
  }

  private func sendDisplayCommandBrightnessContrast(mediaKey: MediaKey, isRepeat _: Bool, isSmallIncrement: Bool, isPressed: Bool, isContrast: Bool = false) {
    guard [.brightnessUp, .brightnessDown].contains(mediaKey), app.sleepID == 0, app.reconfigureID == 0, isPressed else {
      return
    }
    let affectedDisplays = self.affectedDisplays(isBrightness: true, isVolume: false)
    os_log("Brightness key %{public}@ targets %{public}@ display(s): %{public}@", type: .default, mediaKey == .brightnessUp ? "up" : "down", String(affectedDisplays.count), affectedDisplays.map { "\($0.identifier) \($0.name)" }.joined(separator: ", "))
    for display in affectedDisplays where !display.readPrefAsBool(key: .isDisabled) {
      switch mediaKey {
      case .brightnessUp:
        if isContrast, let otherDisplay = display as? OtherDisplay {
          otherDisplay.stepContrast(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
        } else {
          var isAnyDisplayInSwAfterBrightnessMode = false
          for display in affectedDisplays where ((display as? OtherDisplay)?.isSwBrightnessNotDefault() ?? false) && !((display as? OtherDisplay)?.isSw() ?? false) && prefs.bool(forKey: PrefKey.separateCombinedScale.rawValue) {
            isAnyDisplayInSwAfterBrightnessMode = true
          }
          if !(isAnyDisplayInSwAfterBrightnessMode && !(((display as? OtherDisplay)?.isSwBrightnessNotDefault() ?? false) && !((display as? OtherDisplay)?.isSw() ?? false))) {
            display.stepBrightness(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
          }
        }
      case .brightnessDown:
        if isContrast, let otherDisplay = display as? OtherDisplay {
          otherDisplay.stepContrast(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
        } else {
          display.stepBrightness(isUp: mediaKey == .brightnessUp, isSmallIncrement: isSmallIncrement)
        }
      default: continue
      }
    }
  }

  private func oppositeMediaKey(mediaKey: MediaKey) -> MediaKey? {
    if mediaKey == .brightnessUp {
      return .brightnessDown
    } else if mediaKey == .brightnessDown {
      return .brightnessUp
    } else if mediaKey == .volumeUp {
      return .volumeDown
    } else if mediaKey == .volumeDown {
      return .volumeUp
    }
    return nil
  }

  func updateMediaKeyTap() {
    var keys: [MediaKey] = []
    if [KeyboardBrightness.media.rawValue, KeyboardBrightness.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardBrightness.rawValue)) {
      keys.append(contentsOf: [.brightnessUp, .brightnessDown])
    }
    if [KeyboardVolume.media.rawValue, KeyboardVolume.both.rawValue].contains(prefs.integer(forKey: PrefKey.keyboardVolume.rawValue)) {
      keys.append(contentsOf: [.mute, .volumeUp, .volumeDown])
    }
    // Remove brightness keys if no external displays are connected, but only if brightness fine control is not active
    var disengageBrightness = true
    for display in DisplayManager.shared.getAllDisplays() where !display.isBuiltIn() {
      disengageBrightness = false
    }
    // Disengage brightness keys on sleep so MacBook native screen can be controlled meanwhile
    if app.sleepID != 0 || app.reconfigureID != 0 {
      disengageBrightness = true
    }
    if disengageBrightness, !prefs.bool(forKey: PrefKey.useFineScaleBrightness.rawValue) {
      let keysToDelete: [MediaKey] = [.brightnessUp, .brightnessDown]
      keys.removeAll { keysToDelete.contains($0) }
    }
    // Remove volume related keys if audio device is controllable
    if let defaultAudioDevice = app.coreAudio.defaultOutputDevice {
      let keysToDelete: [MediaKey] = [.volumeUp, .volumeDown, .mute]
      if prefs.integer(forKey: PrefKey.multiKeyboardVolume.rawValue) == MultiKeyboardVolume.audioDeviceNameMatching.rawValue {
        if DisplayManager.shared.updateAudioControlTargetDisplays(deviceName: defaultAudioDevice.name) == 0 {
          keys.removeAll { keysToDelete.contains($0) }
        }
      } else if defaultAudioDevice.canSetVirtualMainVolume(scope: .output) == true {
        keys.removeAll { keysToDelete.contains($0) }
      }
    }
    self.mediaKeyTap?.stop()
    self.mediaKeyTap = nil
    self.watchedKeys = keys
    // returning an empty array listens for all mediakeys in MediaKeyTap
    if keys.count > 0 {
      self.mediaKeyTap = MediaKeyTap(delegate: self, on: KeyPressMode.keyDownAndUp, for: keys, observeBuiltIn: true)
      self.mediaKeyTap?.start()
    }
    os_log("Media key tap registered for: %{public}@ (Accessibility trusted: %{public}@)", type: .default, keys.isEmpty ? "nothing (tap not active)" : keys.map { String(describing: $0) }.joined(separator: ", "), String(AXIsProcessTrusted()))
    self.startDiagnosticTap(active: !keys.isEmpty)
  }

  // MARK: - Diagnostic event tap

  // A second, listen-only tap that never consumes anything. It exists purely to answer two questions in the log when the
  // keys "do nothing": can this process create an event tap at all (if not, the Accessibility permission is not effective
  // despite what System Settings shows), and which events do the brightness keys actually generate on this machine.
  // Only media key related events are ever logged, regular typing is ignored.
  static var diagnosticTapPort: CFMachPort?
  static var diagnosticTapRunLoopSource: CFRunLoopSource?

  func startDiagnosticTap(active: Bool) {
    self.stopDiagnosticTap()
    guard active else {
      return
    }
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << NX_SYSDEFINED)
    let callback: CGEventTapCallBack = { _, type, event, _ in
      MediaKeyTapManager.logDiagnosticEvent(type: type, event: event)
      return Unmanaged.passUnretained(event)
    }
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: nil) else {
      os_log("Diagnostic event tap could NOT be created. macOS refuses event taps for this process, so the media key tap cannot work either. Accessibility trusted: %{public}@. Remove MonitorControl from System Settings > Privacy & Security > Accessibility (and Input Monitoring, if listed) and add it again.", type: .error, String(AXIsProcessTrusted()))
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
      os_log("Diagnostic event tap: run loop source could not be created", type: .error)
      return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    MediaKeyTapManager.diagnosticTapPort = port
    MediaKeyTapManager.diagnosticTapRunLoopSource = source
    os_log("Diagnostic event tap created, listening for media key events", type: .default)
  }

  func stopDiagnosticTap() {
    if let source = MediaKeyTapManager.diagnosticTapRunLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      CFRunLoopSourceInvalidate(source)
    }
    if let port = MediaKeyTapManager.diagnosticTapPort {
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
    }
    MediaKeyTapManager.diagnosticTapRunLoopSource = nil
    MediaKeyTapManager.diagnosticTapPort = nil
  }

  static func logDiagnosticEvent(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      os_log("Diagnostic event tap was disabled by the system (%{public}@), re-enabling", type: .default, type == .tapDisabledByTimeout ? "timeout" : "user input")
      if let port = MediaKeyTapManager.diagnosticTapPort {
        CGEvent.tapEnable(tap: port, enable: true)
      }
      return
    }
    if type == .keyDown {
      let keycode = event.getIntegerValueField(.keyboardEventKeycode)
      let names: [Int64: String] = [144: "brightness up (function key code 144)", 145: "brightness down (function key code 145)", 107: "F14", 113: "F15", 122: "F1", 120: "F2"]
      if let name = names[keycode] {
        os_log("Diagnostic event tap: keyDown %{public}@, flags %{public}@", type: .default, name, String(event.flags.rawValue, radix: 16))
      }
      return
    }
    guard type.rawValue == UInt32(NX_SYSDEFINED), let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
      return
    }
    let keycode = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
    let keyFlags = nsEvent.data1 & 0x0000_FFFF
    let pressed = ((keyFlags & 0xFF00) >> 8) == 0xA
    let names: [Int32: String] = [NX_KEYTYPE_BRIGHTNESS_UP: "brightness up", NX_KEYTYPE_BRIGHTNESS_DOWN: "brightness down", NX_KEYTYPE_SOUND_UP: "volume up", NX_KEYTYPE_SOUND_DOWN: "volume down", NX_KEYTYPE_MUTE: "mute", NX_KEYTYPE_ILLUMINATION_UP: "keyboard illumination up", NX_KEYTYPE_ILLUMINATION_DOWN: "keyboard illumination down"]
    guard let name = names[keycode] else {
      return
    }
    os_log("Diagnostic event tap: system-defined media key %{public}@ (code %{public}@) %{public}@", type: .default, name, String(keycode), pressed ? "pressed" : "released")
  }

  // Re-register the tap so that it is in front of any event tap another process registered in the meantime. macOS delivers
  // key events to the most recently inserted head tap first, so a tap that was registered later (by the system or another
  // app) can quietly take the brightness keys away from us. Users noticed that opening the settings window, which happens
  // to re-register the tap, brought the keys back; this does the same thing automatically.
  func refreshMediaKeyTapIfIdle() {
    guard !self.watchedKeys.isEmpty else {
      return
    }
    guard CACurrentMediaTime() - self.lastMediaKeyEventTime > 3 else {
      return // a key was used a moment ago (or is being held), do not disturb it
    }
    os_log("Re-registering the media key tap to keep it in front of other event taps", type: .info)
    self.updateMediaKeyTap()
  }

  func handleOpenPrefPane(mediaKey: MediaKey, event: KeyEvent?, modifiers: NSEvent.ModifierFlags?) -> Bool {
    guard let modifiers = modifiers else { return false }
    if !(modifiers.contains(.option) && !modifiers.contains(.shift) && !modifiers.contains(.control) && !modifiers.contains(.command)) {
      return false
    }
    if event?.keyRepeat == true {
      return false
    }
    switch mediaKey {
    case .brightnessUp, .brightnessDown:
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Displays.prefPane"))
    case .mute, .volumeUp, .volumeDown:
      NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane"))
    default:
      return false
    }
    return true
  }

  static func acquirePrivileges(firstAsk: Bool = false) {
    if !self.readPrivileges(prompt: true), !firstAsk {
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Shortcuts not available", comment: "Shown in the alert dialog")
      alert.informativeText = NSLocalizedString("You need to enable MonitorControl in System Settings > Security and Privacy > Accessibility for the keyboard shortcuts to work", comment: "Shown in the alert dialog")
      alert.runModal()
    }
  }

  static func readPrivileges(prompt: Bool) -> Bool {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: prompt]
    let status = AXIsProcessTrustedWithOptions(options)
    os_log("Reading Accessibility privileges - Current access status %{public}@", type: .info, String(status))
    return status
  }
}
