import AppKit
import Carbon
import Carbon.HIToolbox
import Combine
import Foundation

/// Global shortcuts that drive the island without touching the trackpad. The main combo lives
/// in preferences (⌃⌥Space out of the box, or ⌃⌥I where macOS switches input sources with
/// that, see `shippingDefault`) and toggles the island; the same modifiers with Tab
/// step forward through every view, with Shift+Tab backward; Escape closes whatever is open,
/// and the modifiers with the arrow keys step sideways; those are only registered while
/// something is open. The Tab and arrow steps need two of ⌃⌥⌘ in the combination, see
/// `stepsAreSafe`. Uses Carbon's RegisterEventHotKey, which works for
/// background apps with no permissions.
final class HotKeyService: ObservableObject {
    /// One owner for the registration, so Settings can watch it while ServiceHub drives it.
    static let shared = HotKeyService()

    /// True when the last registration attempt was refused — almost always because another
    /// app already owns the combo. Settings surfaces this next to the recorder.
    @Published private(set) var registrationFailed = false
    /// True when macOS itself uses the combo for one of its own shortcuts, see `systemConflict`.
    /// Registration still succeeds for those, which is why this is a second flag rather than
    /// the first one saying yes.
    @Published private(set) var takenBySystem = false

    /// ⌃⌥Space: the shipping default, and what the recorder's "Reset" button restores on a Mac
    /// where macOS leaves it free.
    static let defaultKeyCode = kVK_Space
    static let defaultModifiers = controlKey | optionKey

    /// ⌃⌥I: what a Mac gets instead where ⌃⌥Space is already macOS's.
    ///
    /// With two input sources, ⌃⌥Space is "Select next source in Input menu", and macOS takes
    /// it before any app sees it — while `RegisterEventHotKey` still says yes, so nothing said
    /// the shortcut the tour had just taught was dead. I is in none of the system's lists, and
    /// clear of the island's own steps, which ride on Tab and the arrows.
    ///
    /// The letter, not the key: a hot key is registered by key code, which is a position, and
    /// where I sits on an American keyboard is the key that types C on a Dvorak one and U on a
    /// Colemak one — while the tour, the recorder and the Reset button all said "⌃⌥I". The key
    /// is found by what it types (`fallbackKey(character:)`), the way the question's keys
    /// are, and named by what it types everywhere it is shown.
    static let fallbackLetter: Character = "i"
    /// Where I sits on an American keyboard: the fallback's key where no key types an I — a
    /// Russian layout, whose keys type Cyrillic — or where the layout cannot be asked.
    static let fallbackKeyCode = kVK_ANSI_I
    static let fallbackModifiers = controlKey | optionKey

    /// The key that types `fallbackLetter` on the layout `character` answers for. The letter
    /// keys first, then the keys around them, which carry the Turkish Q layout's dotted i.
    /// Pure, so a test can put any layout to it.
    static func fallbackKey(character: (Int) -> String?) -> Int {
        keyCode(typing: fallbackLetter, among: letterKeyCodes + punctuationKeyCodes,
                character: character, otherwise: fallbackKeyCode)
    }

    private enum Slot: UInt32 {
        case toggle = 1, next = 2, previous = 3, escape = 4, left = 5, right = 6
        /// Claimed only while the panel is pinned open on a section nobody types into.
        case panelLeft = 7, panelRight = 8, volumeUp = 9, volumeDown = 10, playPause = 11
        /// Control-Y and Control-N, claimed only while a question from `notchctl ask` is up.
        case askYes = 12, askNo = 13
    }

    /// The panel's own keys that do one job whatever the layout: the arrows and Space. The
    /// keys that do what they type are `typingKeys`, released with these.
    private static let panelSlots: [Slot] = [.panelLeft, .panelRight, .volumeUp, .volumeDown, .playPause]

    /// A key the panel claims for what it types rather than for one job of its own.
    ///
    /// These used to be the twenty-six keys where A to Z sit on an American keyboard and the
    /// ten figures of its number row, each with its job fixed by that position. Everywhere
    /// else that was wrong in two ways. Letters that live on the keys around the alphabet —
    /// the French M, the German Ö Ä Ü and ß, the Scandinavian Å Ä Ö Æ Ø, the Spanish Ñ, seven
    /// Russian letters, the Turkish i — were never claimed, so no find could start with them.
    /// And the letters on a French or Czech number row — é è ç à, ě š č ř ž ý á í é — jumped
    /// the switcher instead of starting a find. So a press is now read for what the layout
    /// types (`keyRole`): a letter is a find where there is a list to search, and only a key
    /// that types no letter falls back to the figure printed on it.
    struct TypingKey: Equatable {
        enum Kind: Equatable {
            /// The row of figures above the letters, nothing held.
            case numberRow
            /// The same row with Shift held, which is how a French or Czech keyboard types its
            /// figures. Claimed only where the layout types a figure with it
            /// (`claims(_:letters:typed:)`), so ⇧2 stays an @ everywhere it is one.
            case shiftedNumberRow
            /// The keypad's figures, which type the same on every layout.
            case keypad
            /// The twenty-six keys that carry the alphabet on an American keyboard.
            case letter
            /// The keys around them, which carry punctuation on an American keyboard and
            /// letters on many others. Claimed only where they type a letter.
            case punctuation
        }

        let keyCode: Int
        let kind: Kind
        /// The figure printed on the key, for the number row and the keypad: what it stands
        /// for where the layout types no figure on it, as a French keyboard types é on the 2.
        let digit: Int?

        /// The modifiers it is registered with.
        var modifiers: Int { kind == .shiftedNumberRow ? shiftKey : 0 }
    }

    /// Every `TypingKey`, in the order their hot key ids are counted from `typingKeyIDBase`.
    static let typingKeys: [TypingKey] = {
        var keys: [TypingKey] = []
        for (code, digit) in zip(numberRowKeyCodes, figures) {
            keys.append(TypingKey(keyCode: code, kind: .numberRow, digit: digit))
        }
        for (code, digit) in zip(numberRowKeyCodes, figures) {
            keys.append(TypingKey(keyCode: code, kind: .shiftedNumberRow, digit: digit))
        }
        for (code, digit) in zip(keypadKeyCodes, figures) {
            keys.append(TypingKey(keyCode: code, kind: .keypad, digit: digit))
        }
        for code in letterKeyCodes { keys.append(TypingKey(keyCode: code, kind: .letter, digit: nil)) }
        for code in punctuationKeyCodes { keys.append(TypingKey(keyCode: code, kind: .punctuation, digit: nil)) }
        return keys
    }()

    /// The first hot key id a typing key is registered under; the rest follow in the order of
    /// `typingKeys`. Clear of every `Slot`.
    static let typingKeyIDBase: UInt32 = 100

    /// The typing key a hot key id was registered for.
    static func typingKey(id: UInt32) -> TypingKey? {
        guard id >= typingKeyIDBase else { return nil }
        let index = Int(id - typingKeyIDBase)
        return typingKeys.indices.contains(index) ? typingKeys[index] : nil
    }

    /// The figures on the number row and the keypad, in the order their keys are listed: one
    /// to nine, then zero, as they run across the keyboard.
    private static let figures = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]

    /// The number row, 1 to 9 and then 0. Their virtual key codes are not consecutive, which
    /// is why they are written out rather than counted.
    static let numberRowKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0]

    /// The keypad's figures, in the same order.
    static let keypadKeyCodes = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
                                 kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8,
                                 kVK_ANSI_Keypad9, kVK_ANSI_Keypad0]

    /// A to Z, in that order. Virtual key codes are positions rather than letters, so what
    /// these twenty-six are is "the keys that carry the alphabet" on an American keyboard;
    /// which letter each of them types on the layout in force is `KeyLayout`'s question, asked
    /// when one is pressed.
    static let letterKeyCodes = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
                                 kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
                                 kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
                                 kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
                                 kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
                                 kVK_ANSI_Z]

    /// The keys around the letters: [ ] ; ' , . / - = ` and \ where an American keyboard has
    /// them, and the ISO key beside 1 (§ on a British Mac). Where Ö, Ä, Ü, Ñ, Å, Ø, the French
    /// M and most of the Russian and Turkish letters are.
    static let punctuationKeyCodes = [kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Semicolon,
                                      kVK_ANSI_Quote, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash,
                                      kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_Grave, kVK_ANSI_Backslash,
                                      kVK_ISO_Section]

    /// Every hot key registered now, by its id: a `Slot`'s raw value, or a typing key's.
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var escapeArmed = false
    private var stepKeysArmed = false
    private var askKeysArmed = false
    /// What the panel is allowed to take from the keyboard at this moment, see `claim`.
    private var panelClaim = KeyClaim.nothing
    private var cancellables = Set<AnyCancellable>()
    private static let signature: OSType = 0x4E4F5443 // "NOTC"

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            // Only our own, well-formed hot keys are acted on; anything else is logged and dropped.
            guard read == noErr, hotKeyID.signature == HotKeyService.signature else {
                IslandLog.keys.error("hot key event ignored: status \(read, privacy: .public) id \(hotKeyID.id, privacy: .public)")
                return noErr
            }
            if let slot = Slot(rawValue: hotKeyID.id) {
                DispatchQueue.main.async { HotKeyService.handle(slot) }
            } else if let key = HotKeyService.typingKey(id: hotKeyID.id) {
                DispatchQueue.main.async { HotKeyService.handle(key) }
            } else {
                IslandLog.keys.error("hot key event ignored: unknown id \(hotKeyID.id, privacy: .public)")
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard status == noErr else {
            handlerRef = nil
            return
        }
        register()
        observePreferences()
    }

    func stop() {
        cancellables.removeAll()
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        registrationFailed = false
        if takenBySystem { takenBySystem = false }
    }

    // MARK: - Registration

    /// Re-registers whenever the recorded combo changes. Debounced so that writing the key code
    /// and the modifiers one after the other costs a single registration.
    private func observePreferences() {
        guard cancellables.isEmpty else { return }
        let prefs = Preferences.shared
        // The switch as well as the combination: with the panel's own keys on, this service
        // keeps running after the shortcut is switched off, so something has to take the
        // shortcut back.
        Publishers.CombineLatest3(prefs.$hotkeyKeyCode, prefs.$hotkeyModifiers, prefs.$hotkeyEnabled)
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.register() }
            .store(in: &cancellables)
    }

    /// Recording a replacement: the live combo must not fire while the user presses keys.
    func suspend() { unregister() }

    func resume() {
        guard handlerRef != nil else { return }
        register()
    }

    private func register() {
        guard handlerRef != nil else { return }
        unregister()
        if Preferences.shared.hotkeyEnabled {
            let modifiers = Self.currentModifiers
            registrationFailed = !register(.toggle, keyCode: Self.currentKeyCode, modifiers: modifiers)
            // Asked every time the combination is registered, which is every time it changes:
            // the list is macOS's, and somebody may have switched one of its entries off, or
            // added an input source for the input menu to switch to, since.
            let taken = Self.systemTakes(keyCode: Self.currentKeyCode, modifiers: modifiers,
                                         symbolic: Self.systemHotKeys(),
                                         keyboardSources: Self.selectableKeyboardSources())
            if takenBySystem != taken { takenBySystem = taken }
            // Tab with the same modifiers cycles views; adding Shift reverses. When the main
            // combo already holds Shift the two coincide, and only the forward step registers.
            // Only where those are nobody else's (`stepsAreSafe`): a combination recorded
            // before the recorder asked for two of ⌃⌥⌘ keeps its toggle and loses its steps.
            if Self.stepsAreSafe(modifiers: modifiers) {
                register(.next, keyCode: kVK_Tab, modifiers: modifiers)
                if modifiers & shiftKey == 0 { register(.previous, keyCode: kVK_Tab, modifiers: modifiers | shiftKey) }
            }
        } else {
            // Nothing was asked of the system, so nothing was refused.
            registrationFailed = false
            if takenBySystem { takenBySystem = false }
        }
        if escapeArmed { registerEscape() }
        if stepKeysArmed { registerStepKeys() }
        if panelClaim.bareKeys { registerPanelKeys() }
        if askKeysArmed { registerAskKeys() }
    }

    /// Escape belongs to whatever is open, not to the shortcut that may have opened it. It is
    /// claimed only while the island has something open and the keyboard is its — see
    /// `ActivityCenter.armsEscape` — so a panel a control click pinned leaves Escape with the
    /// app in front.
    private func registerEscape() {
        register(.escape, keyCode: kVK_Escape, modifiers: 0)
    }

    /// The main combo's modifiers with the arrow keys, which step between sections the way a
    /// swipe does. Claimed the whole time the island has something open, whether or not it
    /// asked for the keyboard: the combo is the island's already, and with two of ⌃⌥⌘ in it
    /// the arrows beside it take nothing from anyone (`stepsAreSafe`); with one they are a
    /// word or a line in every text field, and are left alone. Separate from Escape, which
    /// comes and goes with the keyboard's invitation.
    private func registerStepKeys() {
        guard Preferences.shared.hotkeyEnabled else { return }
        let modifiers = Self.currentModifiers
        guard Self.stepsAreSafe(modifiers: modifiers) else { return }
        // Both are registered whatever the other does; `&&` would skip the second.
        let left = register(.left, keyCode: kVK_LeftArrow, modifiers: modifiers)
        let right = register(.right, keyCode: kVK_RightArrow, modifiers: modifiers)
        let arrows = left && right
        // Another app owning the combo costs the arrows, not the shortcut itself, so this is
        // logged rather than shown beside the recorder.
        if !arrows { IslandLog.keys.notice("arrow keys unavailable: another app owns the combo") }
    }

    private func unregisterStepKeys() {
        unregister(.left)
        unregister(.right)
    }

    /// The keys the panel answers on its own, with nothing held down: the arrows step between
    /// views the way a sideways swipe does, the digits go straight to a slot of the switcher,
    /// Space plays and pauses, and the vertical arrows move the volume — the keyboard's
    /// version of a scroll. Claimed only while `claim` says they are the island's, which is
    /// while its own window holds the keyboard and nothing on it is being typed into.
    private func registerPanelKeys() {
        register(.panelLeft, keyCode: kVK_LeftArrow, modifiers: 0)
        register(.panelRight, keyCode: kVK_RightArrow, modifiers: 0)
        register(.volumeUp, keyCode: kVK_UpArrow, modifiers: 0)
        register(.volumeDown, keyCode: kVK_DownArrow, modifiers: 0)
        register(.playPause, keyCode: kVK_Space, modifiers: 0)
        // The figures and, where there is a list to look through, the letters — each asked of
        // the layout in force for whether it is worth taking at all (`claims`). The layout is
        // looked at once for each set of modifiers, not once a key.
        let letters = panelClaim.letters
        let plain = letters ? KeyLayout.characters(for: Self.punctuationKeyCodes) : [:]
        let shifted = KeyLayout.characters(for: Self.numberRowKeyCodes, modifiers: shiftKey)
        for (index, key) in Self.typingKeys.enumerated() {
            let typed = key.kind == .shiftedNumberRow ? shifted[key.keyCode] : plain[key.keyCode]
            guard Self.claims(key.kind, letters: letters, typed: typed) else { continue }
            register(id: Self.typingKeyIDBase + UInt32(index), keyCode: key.keyCode, modifiers: key.modifiers)
        }
    }

    private func unregisterPanelKeys() {
        for slot in Self.panelSlots { unregister(slot) }
        for index in Self.typingKeys.indices { unregister(id: Self.typingKeyIDBase + UInt32(index)) }
    }

    /// Whether a typing key is worth claiming, given whether the section is a list to look
    /// through and what the key types on the layout in force.
    ///
    /// The number row and the keypad always: a figure, or a slot of the switcher, wherever the
    /// panel is. The number row with Shift only where it types a figure — the French and Czech
    /// way of typing one — so that on an American keyboard ⇧2 is left alone as it always was.
    /// The letter keys wherever there is a list to search. The keys around them only where they
    /// type a letter as well, which on an American keyboard is none of them, so nothing more
    /// is taken there than before; on a German one it is Ö, Ä and Ü, on a French one the M.
    /// Pure, so any layout can be put to it.
    static func claims(_ kind: TypingKey.Kind, letters: Bool, typed: String?) -> Bool {
        switch kind {
        case .numberRow, .keypad: return true
        case .shiftedNumberRow: return figure(typed) != nil
        case .letter: return letters
        case .punctuation: return letters && PanelFind.opensFind(typed ?? "")
        }
    }

    /// Control-Y and Control-N answer the question `notchctl ask` put on the island. Claimed
    /// from every app at once, which is why only for as long as a question is up: Control-N is
    /// the line below in every text field on the Mac, and Control-Y puts back what Control-K
    /// took. Found by the letters they type on the layout in force rather than by where Y and
    /// N sit on an American keyboard — on a German one that is the key marked Z.
    private func registerAskKeys() {
        let letters = Self.letterKeyCodes
        let yes = register(.askYes, keyCode: Self.askKeyCode(typing: "y", among: letters, character: KeyLayout.character(for:)),
                           modifiers: controlKey)
        let no = register(.askNo, keyCode: Self.askKeyCode(typing: "n", among: letters, character: KeyLayout.character(for:)),
                          modifiers: controlKey)
        if !(yes && no) { IslandLog.keys.notice("Control-Y or Control-N unavailable: another app owns it") }
    }

    private func unregisterAskKeys() {
        unregister(.askYes)
        unregister(.askNo)
    }

    /// The key that types `letter` on the layout in force, out of the letter keys; the American
    /// position where no key types it — a Russian layout, whose keys type Cyrillic — since the
    /// keys have to be somewhere, and that is where the card's hint is most likely to be read.
    ///
    /// Pure: the layout is asked through `character`, so the rule can be tested for any of them.
    static func askKeyCode(typing letter: Character, among codes: [Int], character: (Int) -> String?) -> Int {
        keyCode(typing: letter, among: codes, character: character,
                otherwise: letter.lowercased() == "n" ? kVK_ANSI_N : kVK_ANSI_Y)
    }

    /// The first of `codes` that types `letter` on the layout `character` answers for, in
    /// either case; `otherwise` where none of them does.
    static func keyCode(typing letter: Character, among codes: [Int], character: (Int) -> String?,
                        otherwise: Int) -> Int {
        let wanted = String(letter).lowercased()
        return codes.first(where: { character($0)?.lowercased() == wanted }) ?? otherwise
    }

    @discardableResult
    private func register(_ slot: Slot, keyCode: Int, modifiers: Int) -> Bool {
        register(id: slot.rawValue, keyCode: keyCode, modifiers: modifiers)
    }

    @discardableResult
    private func register(id: UInt32, keyCode: Int, modifiers: Int) -> Bool {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRefs[id] = ref
        return true
    }

    private func unregister() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    private func unregister(_ slot: Slot) {
        unregister(id: slot.rawValue)
    }

    private func unregister(id: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    /// Escape is claimed only while the island has something open and the keyboard is its,
    /// so it never interferes with other apps the rest of the time.
    func setEscapeArmed(_ armed: Bool) {
        guard armed != escapeArmed else { return }
        escapeArmed = armed
        guard handlerRef != nil else { return }
        if armed { registerEscape() } else { unregister(.escape) }
    }

    /// The combo's arrows are claimed for as long as something is open, see `registerStepKeys`.
    func setStepKeysArmed(_ armed: Bool) {
        guard armed != stepKeysArmed else { return }
        stepKeysArmed = armed
        guard handlerRef != nil else { return }
        if armed { registerStepKeys() } else { unregisterStepKeys() }
    }

    /// The question's two keys, claimed while `notchctl ask` has a question up and given back
    /// the moment it is answered, runs out or is replaced — see `IslandAsk`. Says whether both
    /// are the island's now, which is whether the card may say they answer it.
    @discardableResult
    func setAskKeysArmed(_ armed: Bool) -> Bool {
        if armed != askKeysArmed {
            askKeysArmed = armed
            if handlerRef != nil {
                if armed { registerAskKeys() } else { unregisterAskKeys() }
            }
        }
        return armed && hotKeyRefs[Slot.askYes.rawValue] != nil && hotKeyRefs[Slot.askNo.rawValue] != nil
    }

    /// The two halves of the claim: the keys the panel answers itself — the arrows, the digits
    /// and Space — and the alphabet, which costs the letter keys and those around them that type
    /// a letter, and only means something where there is a list to look through.
    struct KeyClaim: Equatable {
        let bareKeys: Bool
        let letters: Bool
        static let nothing = KeyClaim(bareKeys: false, letters: false)
    }

    /// Whether the island may take a bare key press out of the world at this moment, and
    /// whether that stretches to the alphabet.
    ///
    /// These keys are registered with Carbon, which takes them from every application at once
    /// and hands them here instead. Being open is no licence for that. A pinned panel does not
    /// activate its app and, until it is asked to, does not take the keyboard either: clicking
    /// the island leaves Mail frontmost with the insertion point still blinking in the reply
    /// somebody is halfway through, and the letters they type next belong to that reply. Taking
    /// them anyway is how a sentence arrived with every letter missing, Space stopped their
    /// music mid-bar, and a 3 typed into a form jumped the switcher.
    ///
    /// So the licence is key status, which is the one thing here nobody has to guess at: while
    /// one of the island's own windows is the key window the system has already settled who the
    /// keyboard belongs to, and it is not the app behind — so nothing claimed can be taken from
    /// anybody. It is a licence and not a delivery route: the presses still arrive through
    /// Carbon, so nothing depends on where the first responder happens to be. And when key
    /// status goes — to another app, or to a menu or a Quick Look panel the island opened
    /// itself — the claim goes with it in the same turn of the run loop, because it is the same
    /// call that lets go of both.
    ///
    /// `textFieldUp` is the other way of the keys not being ours. The Notes scratchpad, or a
    /// find already running, is somewhere the user types *into* the island, and a key taken as
    /// a hot key never reaches the field it was meant for.
    ///
    /// Every key class goes the same way, and deliberately so. The digits and the arrows and
    /// Space do less damage than a letter — a caret moved, a track paused — but each of them is
    /// a keystroke somebody pressed while looking somewhere else, and there is no honest line
    /// to draw between them. The keyboard shortcut's own combinations are untouched: two of ⌃⌥⌘
    /// with Tab or an arrow are nobody else's to lose (`stepsAreSafe`), so those stay claimed
    /// the whole time the island is open, and a panel that never gets the keyboard can still be
    /// steered with them.
    static func claim(pinnedOpen: Bool, holdsKeyboard: Bool, textFieldUp: Bool,
                      listSection: Bool, enabled: Bool) -> KeyClaim {
        guard enabled, pinnedOpen, holdsKeyboard, !textFieldUp else { return .nothing }
        return KeyClaim(bareKeys: true, letters: listSection)
    }

    /// Settles what is claimed. Both halves at once: the letters come and go as the panel steps
    /// from one section to the next while the rest of the keys stay put, so a change to either
    /// re-registers the set. See `ActivityCenter.panelClaim`, which holds the state `claim`
    /// reads.
    func setPanelKeys(_ claim: KeyClaim) {
        guard claim != panelClaim else { return }
        panelClaim = claim
        guard handlerRef != nil else { return }
        unregisterPanelKeys()
        if claim.bareKeys { registerPanelKeys() }
    }

    static var currentKeyCode: Int {
        normalized(Preferences.shared.hotkeyKeyCode, fallback: defaultKeyCode)
    }

    static var currentModifiers: Int {
        let stored = normalized(Preferences.shared.hotkeyModifiers, fallback: defaultModifiers)
        // Without a modifier the island would claim Tab and the arrow keys system-wide. The
        // recorder refuses such a combo; a hand-edited defaults entry is refused here. One
        // modifier keeps its shortcut and loses its steps instead, see `stepsAreSafe`.
        return stored == 0 ? defaultModifiers : stored
    }

    /// Whether the steps — Tab, Shift-Tab and the arrows, each with the shortcut's own
    /// modifiers — may be taken from every app: only when those hold at least two of Control,
    /// Option and Command.
    ///
    /// Carbon takes a registered combination from every application at once, and with one
    /// modifier the steps are keys people edit with all day: ⌃Tab moves between tabs in every
    /// browser and in Xcode, ⌥← and ⌥→ jump a word, ⌘← and ⌘→ go to either end of the line,
    /// Shift-Tab goes back a field and Shift with an arrow extends a selection. With ⌃K
    /// recorded, ⌃Tab stopped switching tabs anywhere on the Mac. Shift is not counted: it
    /// is half of the backward step already. The recorder refuses such a combination
    /// (`ShortcutRecorderView.Rejection.tooFewModifiers`); one stored before it did keeps
    /// opening and closing the island, and the steps are left to the app in front.
    static func stepsAreSafe(modifiers: Int) -> Bool {
        [controlKey, optionKey, cmdKey].filter { modifiers & $0 != 0 }.count >= 2
    }

    /// Preferences store these as Doubles; a stale or hand-edited defaults entry must never
    /// blow up an `Int()` conversion or hand Carbon a nonsense key code.
    static func normalized(_ value: Double, fallback: Int) -> Int {
        guard value.isFinite, value >= 0, value <= Double(UInt16.max) else { return fallback }
        return Int(value)
    }

    // MARK: - macOS's own shortcuts

    /// Whether macOS itself uses a combination for one of its own shortcuts that is switched
    /// on: the input menu, Spotlight, Mission Control and the rest of Keyboard Shortcuts.
    ///
    /// `RegisterEventHotKey` knows nothing of these. It says yes to a combination the system
    /// will take first, so "Another app is already using this shortcut" never showed for the
    /// one that mattered most — the shipping ⌃⌥Space on any Mac with two input sources.
    /// `symbolic` is what `CopySymbolicHotKeys` hands back, passed in so the rule can be put a
    /// fixture; an entry that is switched off takes nothing from anyone, so only the enabled
    /// ones count.
    static func systemConflict(keyCode: Int, modifiers: Int, symbolic: [[String: Any]]) -> Bool {
        let wanted = carbonModifiers(symbolic: modifiers)
        return symbolic.contains { entry in
            guard (entry[symbolicEnabledKey] as? Bool) == true,
                  let code = entry[symbolicCodeKey] as? Int,
                  let mask = entry[symbolicModifiersKey] as? Int else { return false }
            return code == keyCode && carbonModifiers(symbolic: mask) == wanted
        }
    }

    /// The four modifiers a symbolic hot key holds, as Carbon masks. `CopySymbolicHotKeys`
    /// writes Carbon's; the same shortcuts as System Settings stores them carry AppKit's
    /// device-independent flags instead, so those are read too rather than trusted to be
    /// absent. Caps Lock, the Fn key and the numeric-pad bit are not part of a combination.
    static func carbonModifiers(symbolic value: Int) -> Int {
        var mask = value & (cmdKey | shiftKey | optionKey | controlKey)
        if value & (1 << 17) != 0 { mask |= shiftKey }
        if value & (1 << 18) != 0 { mask |= controlKey }
        if value & (1 << 19) != 0 { mask |= optionKey }
        if value & (1 << 20) != 0 { mask |= cmdKey }
        return mask
    }

    /// Whether the combination is one of the input menu's two as macOS ships them: ⌃Space for
    /// the previous source and ⌃⌥Space for the next (symbolic hot keys 60 and 61).
    static func isInputMenuCombination(keyCode: Int, modifiers: Int) -> Bool {
        guard keyCode == kVK_Space else { return false }
        let mask = carbonModifiers(symbolic: modifiers)
        return mask == controlKey || mask == controlKey | optionKey
    }

    /// Whether switching input sources can do anything: it needs two keyboard sources to
    /// switch between. Pure over the count `selectableKeyboardSources` reads.
    static func inputMenuSwitches(keyboardSources: Int) -> Bool {
        keyboardSources > 1
    }

    /// Whether macOS answers the combination before the island can, on a Mac with
    /// `keyboardSources` keyboard input sources to choose from: `systemConflict`, except that
    /// the input menu's own two take nothing where there is nothing to switch between.
    ///
    /// macOS lists the input menu's shortcuts switched on whether there is one source or ten,
    /// and with one they do nothing and take nothing — ⌃⌥Space reaches the app in front. Read
    /// as taken, a Mac with one keyboard layout was moved to ⌃⌥I for a shortcut nothing else
    /// had, and moved back and forth at each launch as a second source came and went. The list
    /// says which combinations are taken, not by what, so a combination the input menu ships
    /// with is taken for the input menu's; one somebody has given to Spotlight instead is,
    /// with one source, missed, and the recorder is where that is put right.
    static func systemTakes(keyCode: Int, modifiers: Int, symbolic: [[String: Any]], keyboardSources: Int) -> Bool {
        if isInputMenuCombination(keyCode: keyCode, modifiers: modifiers),
           !inputMenuSwitches(keyboardSources: keyboardSources) {
            return false
        }
        return systemConflict(keyCode: keyCode, modifiers: modifiers, symbolic: symbolic)
    }

    /// The combination this Mac gets while nobody has recorded one: ⌃⌥Space, or ⌃⌥I where
    /// macOS uses ⌃⌥Space to switch input sources — see `fallbackKeyCode` — with I found by
    /// what the keys type on the layout `character` answers for (`fallbackKey(character:)`).
    /// Pure over `symbolic`, the count of keyboard sources and the layout.
    static func shippingDefault(symbolic: [[String: Any]], keyboardSources: Int,
                                character: (Int) -> String?) -> (keyCode: Int, modifiers: Int) {
        systemTakes(keyCode: defaultKeyCode, modifiers: defaultModifiers, symbolic: symbolic,
                    keyboardSources: keyboardSources)
            ? (fallbackKey(character: character), fallbackModifiers)
            : (defaultKeyCode, defaultModifiers)
    }

    /// The same, from this Mac's own list, input sources and layout. What Preferences writes
    /// down the first time the app runs, and what the recorder's Reset goes back to. Main thread.
    static var shippingDefaultOnThisMac: (keyCode: Int, modifiers: Int) {
        shippingDefault(symbolic: systemHotKeys(), keyboardSources: selectableKeyboardSources(),
                        character: KeyLayout.character(for:))
    }

    /// The fallback as it reads on the layout `character` answers for: "⌃⌥I" wherever a key
    /// types an I, whichever key that is. What the recorder's Reset button names beside
    /// ⌃⌥Space, so that the two can never disagree about which key it is.
    static func fallbackDisplay(character: (Int) -> String?) -> String {
        displayString(keyCode: fallbackKey(character: character), carbonModifiers: fallbackModifiers,
                      character: character)
    }

    /// How many keyboard input sources the input menu can switch between: the enabled
    /// keyboard layouts and input modes that can be selected. Emoji & Symbols and the other
    /// palettes are not keyboard sources, and a source that cannot be chosen from the menu is
    /// not one to switch to. None where the list cannot be read.
    ///
    /// Main thread only, as the Text Input Sources calls are, and recent macOS traps one made
    /// from any other. Asked from another thread anyway, it says two without asking, which
    /// leaves the input menu's shortcuts counted as taken — what this was before it counted.
    static func selectableKeyboardSources() -> Int {
        guard Thread.isMainThread else { return 2 }
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as [String: Any]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() else { return 0 }
        return CFArrayGetCount(list)
    }

    /// macOS's own shortcuts, as `CopySymbolicHotKeys` lists them; none where it will not say,
    /// which is read as nothing being taken rather than as everything.
    static func systemHotKeys() -> [[String: Any]] {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let entries = list?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return entries
    }

    /// The keys each entry of that list is read by.
    static let symbolicCodeKey = kHISymbolicHotKeyCode as String
    static let symbolicModifiersKey = kHISymbolicHotKeyModifiers as String
    static let symbolicEnabledKey = kHISymbolicHotKeyEnabled as String

    // MARK: - Actions

    /// How long after the panel opens an Escape is still taken for the tail of the click or
    /// key press that opened it.
    static let escapeTail: TimeInterval = 0.3

    /// Whether an Escape `sinceOpened` seconds after the panel opened is the tail of that open
    /// rather than a press of its own. Measured from the open alone (`ActivityCenter.openedAt`),
    /// not from the last thing done on the panel: every step, slider, find and pick moves
    /// `lastInteraction`, so Escape pressed twice to leave a find and then close did nothing
    /// the second time, Tab-Tab-Escape typed quickly lost the Escape — and Carbon had already
    /// taken it, so no other app got it either. The click-outside guard learned this first.
    /// A clock that has gone backwards since the open is not a tail.
    static func escapeIsTail(sinceOpened: TimeInterval) -> Bool {
        (0...escapeTail).contains(sinceOpened)
    }

    private static func handle(_ slot: Slot) {
        let center = ActivityCenter.shared
        let sinceOpened = Date().timeIntervalSince(center.openedAt)
        IslandLog.keys.notice("hot key \(slot.rawValue, privacy: .public) \(sinceOpened, privacy: .public)s after opening")
        switch slot {
        case .toggle: center.toggle()
        case .next: center.cycleView(forward: true)
        case .previous: center.cycleView(forward: false)
        case .left: _ = center.step(forward: false, wrap: false)
        case .right: _ = center.step(forward: true, wrap: false)
        case .escape:
            // Escape is registered the instant something opens; nothing in the tail of that
            // click may pass for a key press.
            guard !escapeIsTail(sinceOpened: sinceOpened) else { return }
            // One step back at a time: a find in progress is what Escape leaves first, the
            // way it does in every window on the Mac that has a search field.
            if center.endFind() { return }
            center.collapse(reason: "escape")
        case .panelLeft: _ = center.step(forward: false, wrap: false)
        case .panelRight: _ = center.step(forward: true, wrap: false)
        // Whatever question is up, from wherever the keyboard is.
        case .askYes: IslandAsk.shared.answer(.yes)
        case .askNo: IslandAsk.shared.answer(.no)
        case .volumeUp: GestureRouter.shared.nudgeVolume(up: true)
        case .volumeDown: GestureRouter.shared.nudgeVolume(up: false)
        case .playPause:
            // On the shelf, Space is Quick Look — where every Mac has taught people to expect
            // it — of what is picked out, as in Finder, and of the whole shelf when nothing
            // is (`ShelfStore.quickLookTargets`). Anywhere else it plays and pauses.
            if center.isShowingShelf, !ShelfStore.shared.items.isEmpty {
                ShelfQuickLook.shared.show(ShelfStore.shared.quickLookTargets)
            } else {
                NowPlayingService.shared.togglePlayPause()
            }
        }
    }

    /// A typing key, read for what it types on the layout in force at the moment it is
    /// pressed rather than for where it sits on an American keyboard — see `keyRole`.
    private static func handle(_ key: TypingKey) {
        let center = ActivityCenter.shared
        let sinceOpened = Date().timeIntervalSince(center.openedAt)
        IslandLog.keys.notice("typing key \(key.keyCode, privacy: .public) \(sinceOpened, privacy: .public)s after opening")
        let section = center.openSection
        let role = keyRole(typed: KeyLayout.character(for: key.keyCode, modifiers: key.modifiers), digit: key.digit,
                           searchable: PanelFind.searches(section), takesEntry: PanelFind.takesEntry(section))
        switch role {
        case .find(let letter):
            // Under an input method the key is the start of a composition, not a letter of
            // the query: the field opens empty and focused for it to be typed again there.
            if KeyLayout.prefillsFindOnThisMac {
                center.beginFind(with: letter)
            } else {
                center.beginFind()
            }
        case .entry(let digits):
            // On Actions a number is a timer's minutes or the start of an alarm's time,
            // typed into the field this opens; the switcher is a Tab or an arrow away.
            center.beginFind(with: digits)
        case .slot(let index):
            center.selectSlot(index)
        case .nothing:
            break
        }
    }

    /// What a press of one of the typing keys does.
    enum KeyRole: Equatable {
        /// Start a find with this letter.
        case find(String)
        /// Open the timer entry on Actions with this figure, always a Western one.
        case entry(String)
        /// Go straight to this slot of the switcher, counting from zero.
        case slot(Int)
        /// Nothing: neither a letter where there is a list, nor a figure.
        case nothing
    }

    /// What a typing key does, given what it types with the modifiers it was pressed with
    /// (`typed`, nil where the layout cannot say), the figure printed on it (`digit`, for the
    /// number row and the keypad), and whether the section on screen is a list to search or
    /// Actions, where figures type a timer.
    ///
    /// What the key types comes first, and only a key that types no letter falls back to the
    /// figure printed on it. A letter is a find wherever there is a list to look through,
    /// whichever key it is on: the é on a French 2 and the ö beside a German L as much as an
    /// A. A figure the layout types is the figure — ⇧2 on a French keyboard is 2, and so is
    /// an Arabic ٢ — and a key that types neither stands for the figure printed on it, so the
    /// French 2 still reaches the second slot where there is nothing to search, and still
    /// types a 2 on Actions. On an American keyboard every figure key types its own figure
    /// and every letter key its own letter, so nothing there changes. Pure, so any layout can
    /// be put to it.
    static func keyRole(typed: String?, digit: Int?, searchable: Bool, takesEntry: Bool) -> KeyRole {
        if searchable, let typed, PanelFind.opensFind(typed) { return .find(typed) }
        guard let value = figure(typed) ?? digit else { return .nothing }
        if takesEntry { return .entry(String(value)) }
        // Zero has no slot of its own.
        return value > 0 ? .slot(value - 1) : .nothing
    }

    /// The figure a key types, when what it types is one: any decimal digit, so that a
    /// full-width ５ or an Arabic ٥ counts as the 5 it is. Nil for anything else, a superscript
    /// ² or a Roman Ⅻ included.
    static func figure(_ typed: String?) -> Int? {
        guard let typed, typed.count == 1, let character = typed.first,
              character.unicodeScalars.count == 1,
              character.unicodeScalars.first?.properties.numericType == .decimal,
              let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
        return value
    }

    // MARK: - Display

    /// "⌃⌥Space", "⇧⌘K", "F5" — modifiers in Apple's canonical order, then the key's name,
    /// which for a key that types something is what it types on the layout `character`
    /// answers for (`keyName`).
    static func displayString(keyCode: Int, carbonModifiers: Int,
                              character: (Int) -> String? = KeyLayout.character(for:)) -> String {
        var text = ""
        if (carbonModifiers & controlKey) != 0 { text += "⌃" }
        if (carbonModifiers & optionKey) != 0 { text += "⌥" }
        if (carbonModifiers & shiftKey) != 0 { text += "⇧" }
        if (carbonModifiers & cmdKey) != 0 { text += "⌘" }
        return text + keyName(for: keyCode, character: character)
    }

    /// A key's name as its own cap would print it.
    ///
    /// A key code is a position, and this used to name each one by the American legend at that
    /// position: a German Mac with ⌃⌥Z recorded was shown ⌃⌥Y, a French one with ⌃⌥A was
    /// shown ⌃⌥Q, and the key beside 1 on every ISO keyboard was "Key 0x0A". A key that types
    /// something is named by what it types on the layout in force, as a capital; the keys that
    /// type nothing — Return, Tab, the arrows, the function keys — by their names; and the
    /// American legend is kept for when the layout cannot be asked.
    static func keyName(for keyCode: Int, character: (Int) -> String? = KeyLayout.character(for:)) -> String {
        if typingKeyCodes.contains(keyCode), let printed = legend(typed: character(keyCode)) { return printed }
        if let name = keyNames[keyCode] { return name }
        let hex = String(keyCode, radix: 16, uppercase: true)
        return "Key 0x" + (hex.count < 2 ? "0" + hex : hex)
    }

    /// The keys named by what they type: the letters, the number row, the keys around the
    /// letters, and the two JIS keys beside them. Not the keypad, whose figures would read as
    /// the number row's.
    static let typingKeyCodes: Set<Int> =
        Set(letterKeyCodes + numberRowKeyCodes + punctuationKeyCodes + [kVK_JIS_Yen, kVK_JIS_Underscore])

    /// What a key's cap says for the character it types: a letter as a capital, the way caps
    /// and menus print one, and anything else as it is. A letter whose capital is two of them
    /// — the German ß — keeps its own form rather than reading as "SS". Nil for nothing, a
    /// space or a control character, which leave the name to the table.
    static func legend(typed: String?) -> String? {
        guard let typed, !typed.isEmpty,
              !typed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let capital = typed.uppercased()
        return capital.count == typed.count ? capital : typed
    }

    /// The AppKit modifier flags of a recorded event, as the Carbon masks RegisterEventHotKey wants.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var mask = 0
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.shift) { mask |= shiftKey }
        if flags.contains(.command) { mask |= cmdKey }
        return mask
    }

    /// Virtual key codes are layout-independent positions; these are the ANSI legends, with
    /// the ISO key beside 1 and the two JIS keys beside the letters as a British and a Japanese
    /// Mac print them. What a typing key is called when the layout cannot be asked.
    private static let keyNames: [Int: String] = [
        10: "§", 93: "¥", 94: "_",
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
