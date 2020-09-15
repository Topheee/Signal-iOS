//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import AVFoundation
import SignalServiceKit
import SignalMessaging
import AVKit

protocol CallAudioServiceDelegate: class {
    func callAudioServiceDidChangeAudioSession(_ callAudioService: CallAudioService)
    func callAudioServiceDidChangeAudioSource(_ callAudioService: CallAudioService, audioSource: AudioSource?)
}

@objc class CallAudioService: NSObject, CallObserver {

    private var vibrateTimer: Timer?
    private let audioPlayer = AVAudioPlayer()
    var handleRinging = false
    weak var delegate: CallAudioServiceDelegate? {
        willSet {
            assert(newValue == nil || delegate == nil)
        }
    }

    // MARK: Vibration config
    private let vibrateRepeatDuration = 1.6

    // Our ring buzz is a pair of vibrations.
    // `pulseDuration` is the small pause between the two vibrations in the pair.
    private let pulseDuration = 0.2

    var audioSession: OWSAudioSession {
        return Environment.shared.audioSession
    }

    var avAudioSession: AVAudioSession {
        return AVAudioSession.sharedInstance()
    }

    // MARK: - Initializers

    override init() {
        super.init()

        // We cannot assert singleton here, because this class gets rebuilt when the user changes relevant call settings

        // Configure audio session so we don't prompt user with Record permission until call is connected.

        audioSession.configureRTCAudio()
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: avAudioSession, queue: nil) { _ in
            assert(!Thread.isMainThread)
            self.audioRouteDidChange()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - CallObserver

    internal func stateDidChange(call: SignalCall, state: CallState) {
        AssertIsOnMainThread()
        self.handleState(call: call)
    }

    internal func muteDidChange(call: SignalCall, isMuted: Bool) {
        AssertIsOnMainThread()

        ensureProperAudioSession(call: call)
    }

    internal func holdDidChange(call: SignalCall, isOnHold: Bool) {
        AssertIsOnMainThread()

        ensureProperAudioSession(call: call)
    }

    internal func hasLocalVideoDidChange(call: SignalCall, hasLocalVideo: Bool) {
        AssertIsOnMainThread()

        ensureProperAudioSession(call: call)
    }

    private let routePicker = AVRoutePickerView()
    public func presentRoutePicker() -> Bool {
        guard let routeButton = routePicker.subviews.first(where: { $0 is UIButton }) as? UIButton else {
            owsFailDebug("Failed to find subview to present route picker, falling back to old system")
            return false
        }

        routeButton.sendActions(for: .touchUpInside)

        return true
    }

    public func requestSpeakerphone(isEnabled: Bool) {
        // This is a little too slow to execute on the main thread and the results are not immediately available after execution
        // anyway, so we dispatch async. If you need to know the new value, you'll need to check isSpeakerphoneEnabled and take
        // advantage of the CallAudioServiceDelegate.callAudioService(_:didUpdateIsSpeakerphoneEnabled:)
        DispatchQueue.global().async {
            do {
                try self.avAudioSession.overrideOutputAudioPort( isEnabled ? .speaker : .none )
            } catch {
                owsFailDebug("failed to set \(#function) = \(isEnabled) with error: \(error)")
            }
        }
    }

    private func audioRouteDidChange() {
        guard let currentAudioSource = currentAudioSource else {
            return owsFailDebug("Switched to route without audio source")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.callAudioServiceDidChangeAudioSource(self, audioSource: currentAudioSource)
        }
    }

    private func ensureProperAudioSession(call: SignalCall?) {
        AssertIsOnMainThread()

        guard let call = call, !call.isEnded else {
            // Revert to default audio
            setAudioSession(category: .soloAmbient,
                            mode: .default)
            return
        }

        if call.state == .localRinging {
            setAudioSession(category: .playback, mode: .default)
        } else if call.hasLocalVideo {
            // Because ModeVideoChat affects gain, we don't want to apply it until the call is connected.
            // otherwise sounds like ringing will be extra loud for video vs. speakerphone

            // Apple Docs say that setting mode to AVAudioSessionModeVideoChat has the
            // side effect of setting options: .allowBluetooth, when I remove the (seemingly unnecessary)
            // option, and inspect AVAudioSession.sharedInstance.categoryOptions == 0. And availableInputs
            // does not include my linked bluetooth device
            setAudioSession(category: .playAndRecord,
                            mode: .videoChat,
                            options: .allowBluetooth)
        } else {
            // Apple Docs say that setting mode to AVAudioSessionModeVoiceChat has the
            // side effect of setting options: .allowBluetooth, when I remove the (seemingly unnecessary)
            // option, and inspect AVAudioSession.sharedInstance.categoryOptions == 0. And availableInputs
            // does not include my linked bluetooth device
            setAudioSession(category: .playAndRecord,
                            mode: .voiceChat,
                            options: .allowBluetooth)
        }
    }

    // MARK: - Service action handlers

    public func didUpdateVideoTracks(call: SignalCall?) {
        Logger.verbose("")

        self.ensureProperAudioSession(call: call)
    }

    public func handleState(call: SignalCall) {
        assert(Thread.isMainThread)

        Logger.verbose("new state: \(call.state)")

        // Stop playing sounds while switching audio session so we don't 
        // get any blips across a temporary unintended route.
        stopPlayingAnySounds()
        self.ensureProperAudioSession(call: call)

        switch call.state {
        case .idle: handleIdle(call: call)
        case .dialing: handleDialing(call: call)
        case .answering: handleAnswering(call: call)
        case .remoteRinging: handleRemoteRinging(call: call)
        case .localRinging: handleLocalRinging(call: call)
        case .connected: handleConnected(call: call)
        case .reconnecting: handleReconnecting(call: call)
        case .localFailure: handleLocalFailure(call: call)
        case .localHangup: handleLocalHangup(call: call)
        case .remoteHangup: handleRemoteHangup(call: call)
        case .remoteHangupNeedPermission: handleRemoteHangup(call: call)
        case .remoteBusy: handleBusy(call: call)
        case .answeredElsewhere: handleAnsweredElsewhere(call: call)
        case .declinedElsewhere: handleAnsweredElsewhere(call: call)
        case .busyElsewhere: handleAnsweredElsewhere(call: call)
        }
    }

    private func handleIdle(call: SignalCall) {
        Logger.debug("")
    }

    private func handleDialing(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")

        // HACK: Without this async, dialing sound only plays once. I don't really understand why. Does the audioSession
        // need some time to settle? Is somethign else interrupting our session?
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.2) {
            self.play(sound: OWSStandardSound.callConnecting.rawValue)
        }
    }

    private func handleAnswering(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")
    }

    private func handleRemoteRinging(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")

        self.play(sound: OWSStandardSound.callOutboundRinging.rawValue)
    }

    private func handleLocalRinging(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")

        startRinging(call: call)
    }

    private func handleConnected(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")
    }

    private func handleReconnecting(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")
    }

    private func handleLocalFailure(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")

        play(sound: OWSStandardSound.callEnded.rawValue)
        handleCallEnded(call: call)
    }

    private func handleLocalHangup(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")

        play(sound: OWSStandardSound.callEnded.rawValue)
        handleCallEnded(call: call)
    }

    private func handleRemoteHangup(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")

        vibrate()

        play(sound: OWSStandardSound.callEnded.rawValue)
        handleCallEnded(call: call)
    }

    private func handleBusy(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")

        play(sound: OWSStandardSound.callBusy.rawValue)

        // Let the busy sound play for 4 seconds. The full file is longer than necessary
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 4.0) {
            self.handleCallEnded(call: call)
        }
    }

    private func handleAnsweredElsewhere(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")

        play(sound: OWSStandardSound.callEnded.rawValue)
        handleCallEnded(call: call)
    }

    private func handleCallEnded(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.debug("")

        // Sometimes (usually but not always) upon ending a call, the currentPlayer does not get
        // played to completion. This is necessary in order for the players
        // audioActivity to remove itself from OWSAudioSession. Otherwise future AudioActivities,
        // like recording a voice note, will be prevented from having their needs met.
        //
        // Furthermore, no interruption delegate is called nor AVAudioSessionInterruptionNotification
        // is posted. I'm not sure why we have to do this.
        if let audioPlayer = currentPlayer {
            audioPlayer.stop()
        }

        // Stop solo audio, revert to default.
        setAudioSession(category: .soloAmbient)
    }

    // MARK: Playing Sounds

    var currentPlayer: OWSAudioPlayer?

    private func stopPlayingAnySounds() {
        currentPlayer?.stop()
        stopRinging()
    }

    private func prepareToPlay(sound: OWSSound) -> OWSAudioPlayer? {
        guard let newPlayer = OWSSounds.audioPlayer(forSound: sound, audioBehavior: .call) else {
            owsFailDebug("unable to build player for sound: \(OWSSounds.displayName(forSound: sound))")
            return nil
        }
        Logger.info("playing sound: \(OWSSounds.displayName(forSound: sound))")

        // It's important to stop the current player **before** starting the new player. In the case that
        // we're playing the same sound, since the player is memoized on the sound instance, we'd otherwise
        // stop the sound we just started.
        self.currentPlayer?.stop()
        self.currentPlayer = newPlayer

        return newPlayer
    }

    private func play(sound: OWSSound) {
        guard let newPlayer = prepareToPlay(sound: sound) else { return }
        newPlayer.play()
    }

    // MARK: - Ringing

    private func startRinging(call: SignalCall) {
        guard handleRinging else {
            Logger.debug("ignoring \(#function) since CallKit handles it's own ringing state")
            return
        }

        vibrateTimer?.invalidate()
        vibrateTimer = .scheduledTimer(withTimeInterval: vibrateRepeatDuration, repeats: true) { [weak self] _ in
            self?.ringVibration()
        }

        guard let player = prepareToPlay(sound: OWSStandardSound.defaultiOSIncomingRingtone.rawValue) else {
            return owsFailDebug("Failed to prepare player for ringing")
        }

        startObservingRingerState { [weak self] isDeviceSilenced in
            AssertIsOnMainThread()

            // We must ensure the proper audio session before
            // each time we play / pause, otherwise the category
            // may have changed and no playback would occur.
            self?.ensureProperAudioSession(call: call)

            if isDeviceSilenced {
                player.pause()
            } else {
                player.play()
            }
        }
    }

    private func stopRinging() {
        guard handleRinging else {
            Logger.debug("ignoring \(#function) since CallKit handles it's own ringing state")
            return
        }
        Logger.debug("")

        // Stop vibrating
        vibrateTimer?.invalidate()
        vibrateTimer = nil

        stopObservingRingerState()

        currentPlayer?.stop()
    }

    // public so it can be called by timer via selector
    public func ringVibration() {
        // Since a call notification is more urgent than a message notifaction, we
        // vibrate twice, like a pulse, to differentiate from a normal notification vibration.
        vibrate()
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + pulseDuration) {
            self.vibrate()
        }
    }

    func vibrate() {
        // TODO implement HapticAdapter for iPhone7 and up
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    // MARK: - AudioSession MGMT
    // TODO move this to CallAudioSession?

    // Note this method is sensitive to the current audio session configuration.
    // Specifically if you call it while speakerphone is enabled you won't see 
    // any connected bluetooth routes.
    var availableInputs: [AudioSource] {
        guard let availableInputs = avAudioSession.availableInputs else {
            // I'm not sure why this would happen, but it may indicate an error.
            owsFailDebug("No available inputs or inputs not ready")
            return [AudioSource.builtInSpeaker]
        }

        Logger.info("availableInputs: \(availableInputs)")
        return [AudioSource.builtInSpeaker] + availableInputs.map { portDescription in
            return AudioSource(portDescription: portDescription)
        }
    }

    var currentAudioSource: AudioSource? {
        get {
            let outputsByType = avAudioSession.currentRoute.outputs.reduce(
                into: [AVAudioSession.Port: AVAudioSessionPortDescription]()
            ) { result, portDescription in
                result[portDescription.portType] = portDescription
            }

            let inputsByType = avAudioSession.currentRoute.inputs.reduce(
                into: [AVAudioSession.Port: AVAudioSessionPortDescription]()
            ) { result, portDescription in
                result[portDescription.portType] = portDescription
            }

            if let builtInMic = inputsByType[.builtInMic], inputsByType[.builtInReceiver] != nil {
                return AudioSource(portDescription: builtInMic)
            } else if outputsByType[.builtInSpeaker] != nil {
                return AudioSource.builtInSpeaker
            } else if let firstRemaining = inputsByType.values.first {
                return AudioSource(portDescription: firstRemaining)
            } else {
                return nil
            }
        }
        set {
            guard currentAudioSource != newValue else { return }

            Logger.info("changing preferred input: \(String(describing: currentAudioSource)) -> \(String(describing: newValue))")

            if let portDescription = newValue?.portDescription {
                do {
                    try avAudioSession.setPreferredInput(portDescription)
                } catch {
                    owsFailDebug("failed setting audio source with error: \(error)")
                }
            } else if newValue == AudioSource.builtInSpeaker {
                requestSpeakerphone(isEnabled: true)
            } else {
                owsFailDebug("Tried to set unexpected audio source")
            }

            delegate?.callAudioServiceDidChangeAudioSource(self, audioSource: newValue)
        }
    }

    private func setAudioSession(category: AVAudioSession.Category,
                                 mode: AVAudioSession.Mode? = nil,
                                 options: AVAudioSession.CategoryOptions = AVAudioSession.CategoryOptions(rawValue: 0)) {

        AssertIsOnMainThread()

        var audioSessionChanged = false
        do {
            if let mode = mode {
                let oldCategory = avAudioSession.category
                let oldMode = avAudioSession.mode
                let oldOptions = avAudioSession.categoryOptions

                guard oldCategory != category || oldMode != mode || oldOptions != options else {
                    return
                }

                audioSessionChanged = true

                if oldCategory != category {
                    Logger.debug("audio session changed category: \(oldCategory) -> \(category) ")
                }
                if oldMode != mode {
                    Logger.debug("audio session changed mode: \(oldMode) -> \(mode) ")
                }
                if oldOptions != options {
                    Logger.debug("audio session changed options: \(oldOptions) -> \(options) ")
                }
                try avAudioSession.setCategory(category, mode: mode, options: options)

            } else {
                let oldCategory = avAudioSession.category
                let oldOptions = avAudioSession.categoryOptions

                guard avAudioSession.category != category || avAudioSession.categoryOptions != options else {
                    return
                }

                audioSessionChanged = true

                if oldCategory != category {
                    Logger.debug("audio session changed category: \(oldCategory) -> \(category) ")
                }
                if oldOptions != options {
                    Logger.debug("audio session changed options: \(oldOptions) -> \(options) ")
                }
                try avAudioSession.ows_setCategory(category, with: options)
            }
        } catch {
            let message = "failed to set category: \(category) mode: \(String(describing: mode)), options: \(options) with error: \(error)"
            owsFailDebug(message)
        }

        if audioSessionChanged {
            Logger.info("")
            self.delegate?.callAudioServiceDidChangeAudioSession(self)
        }
    }

    // mark: - Ringer State

    // let encodedDarwinNotificationName = "com.apple.springboard.ringerstate".encodedForSelector
    private static let ringerStateNotificationName = DarwinNotificationName("dAF+P3ICAn12PwUCBHoAeHMBcgR1PwR6AHh2BAUGcgZ2".decodedForSelector!)

    private var ringerStateToken: Int32?
    private func startObservingRingerState(stateChanged: @escaping (_ isDeviceSilenced: Bool) -> Void) {

        func isRingerStateSilenced(token: Int32) -> Bool {
            return DarwinNotificationCenter.getStateForObserver(token) > 0 ? false : true
        }

        let token = DarwinNotificationCenter.addObserver(
            for: Self.ringerStateNotificationName,
            queue: .main
        ) { stateChanged(isRingerStateSilenced(token: $0)) }
        ringerStateToken = token
        stateChanged(isRingerStateSilenced(token: token))
    }

    private func stopObservingRingerState() {
        guard let ringerStateToken = ringerStateToken else { return }
        DarwinNotificationCenter.removeObserver(ringerStateToken)
        self.ringerStateToken = nil
    }
}
