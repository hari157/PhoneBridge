# Android Cellular Calls on macOS: Research Report

Date: 2026-10-22. Test Mac: macOS 27.0.1 (build 26A434), Apple silicon (arm64).

## Short answers

| Question | Answer |
|---|---|
| Can Android calls go directly into the native Phone app? | No. |
| What blocks it? | The Phone app gets iPhone calls only through a private Apple relay service. That service needs an Apple-registered iPhone on the same Apple Account. macOS has no public API for a third-party call provider. |
| Can a companion service fill the gap without changes to protected macOS parts? | Yes, as a separate app. It cannot feed calls into the Phone app. |
| Closest native experience? | A Mac app that acts as a Bluetooth hands-free device for the Android phone, plus an optional Android companion app over Wi-Fi. The Mac app becomes the handler for `tel:` links and uses native notifications. |
| Can a separate app give equal function? | Call control, yes: tests on macOS 27 with the OnePlus 7T passed for incoming detection, dial, answer, hang-up, and call state (section 9c). Call audio through the Mac's built-in Bluetooth, no: macOS refuses it by design (sections 9b and 9d). Audio needs a second Bluetooth radio, for example a USB adapter in a Linux VM (`call-audio-setup.md`). |

## 1. How the Phone app talks to an iPhone

The Phone app (`/System/Applications/Phone.app`, bundle ID `com.apple.mobilephone`) is an iOS-style app. It loads its frameworks from `/System/iOSSupport`. It does not talk to the iPhone itself. It asks a system daemon, `callservicesd`, to do the work.

Evidence from the Phone app binary:

- Linked private frameworks: `TelephonyUtilities`, `IDS`, `CallHistory`, `PhoneKit`, `CallsAppServices`, `CallsDialer`, `ConversationKit`.
- Linked public framework: `LiveCommunicationKit`.
- Entitlement `com.apple.telephonyutilities.callservicesd`. This lets the app connect to the call daemon.
- Entitlements `com.apple.private.ids.*` and `com.apple.CommCenter.fine-grained` (values `phone`, `identity`, `cellular-plan`).

Evidence from `callservicesd` (`/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd`):

- Entitlements `com.apple.private.alloy.phonecontinuity`, `com.apple.private.alloy.phone.auth`, `com.apple.private.ids.session`, `com.apple.private.ids.messaging`. "Alloy" is the internal name for services that run on Apple's Identity Services (IDS).
- Wake topics in its launch file: `com.apple.private.alloy.phonecontinuity-idswake` and `com.apple.private.alloy.phonecontinuity.ping-idswake`.
- Class names: `CSDRelayClientController`, `CSDRelayHostController`, `CSDRelayIDSSessionMessenger`, `CSDRelayPairedDeviceMessenger`, `CSDRelayConferenceConnection`.
- Log strings: `relayCapableDeviceExists`, `availableOutgoingRelayCallerIDs`, `setRelayCallingEnabled:forDeviceWithID:`. "Thumper" strings refer to Wi-Fi Calling on other devices.

The call flow, as the evidence shows it:

1. The iPhone and the Mac sign in to the same Apple Account. Each device registers with IDS. IDS is Apple's private identity and messaging service.
2. The iPhone announces that it can relay calls. The Mac records it as a "relay capable device".
3. Call events (incoming, dial, answer, end, state) travel as IDS messages on the `phonecontinuity` service.
4. Call audio travels in an IDS session through Apple's conference engine (`CSDRelayConferenceConnection`, `CSDAVCSession`). Bluetooth Low Energy and Wi-Fi find the nearby device. The audio does not use Bluetooth HFP.

## 2. Public and private parts

| Part | Mechanism | Public? |
|---|---|---|
| Phone app user interface | `CallsAppUI`, `CallsDialer` | Private |
| Call control and state | `TelephonyUtilities` over XPC to `callservicesd` | Private |
| Phone discovery and trust | IDS plus Apple Account, Bluetooth Low Energy | Private |
| Call event transport | IDS service `phonecontinuity` | Private |
| Call audio | IDS session and the AVConference engine | Private |
| Call history | `CallHistory` | Private |
| Headset audio routes | Bluetooth (`CSDBluetoothHangupCommandObserver`) | Internal use only |

Each private part needs entitlements that only Apple-signed binaries can hold. System Integrity Protection guards these binaries. No supported method exists to add an entitlement to the Phone app or to `callservicesd`.

## 3. Third-party call providers on macOS

The macOS SDK on this Mac (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`) shows these facts:

- CallKit: `CXProvider` is marked `API_UNAVAILABLE(macos)`. It is available for Mac Catalyst 13.0 and later. Mac Catalyst is the method that runs an iPad-style app on the Mac.
- LiveCommunicationKit: 44 declarations carry `@available(macOS, unavailable)`. That includes `ConversationManager`, `TelephonyConversationManager`, `StartCellularConversationAction`, and `ConversationHistoryManager`. The cellular classes are iOS 26 only.
- `callservicesd` publishes `com.apple.callkit.callsourcehost`. This hosts CallKit providers on the Mac. A Mac Catalyst app with `CXProvider` can probably show calls in the system call interface. This report did not test whether those calls also show in the Phone app Recents list.
- The `tel:` link handler on this Mac is `Phone.app`. A third-party app can register for `tel:` and ask the user to make it the default.

No documented API lets a third party add a cellular line to the Phone app. A Mac Catalyst CallKit app is the only public way to get the system call experience.

## 4. Can Android emulate the needed device?

| Method | Result |
|---|---|
| Act as an iPhone over IDS | Not possible. Android cannot register as an Apple device in IDS. A copy of the protocol needs Apple device credentials. This bypasses Apple's protections and is out of scope. |
| Bluetooth HFP | Possible. Every Android phone is an HFP Audio Gateway (the phone side of a car kit). The Mac can be the Hands-Free unit through `IOBluetoothHandsFreeDevice`. |
| Wi-Fi from a companion app | Control and data only. Android does not let normal apps capture or inject cellular call audio. The `VOICE_CALL` audio source needs `CAPTURE_AUDIO_OUTPUT`, a system-only permission. |
| USB | Not useful. Android does not send cellular call audio to a computer over USB. `adb` gives control commands only, for development. |

`IOBluetoothHandsFreeDevice` is public in the macOS 27 SDK (`API_AVAILABLE(macos(10.7))`). The SDK does not mark it as deprecated. It gives these calls:

- `dialNumber:`, `redial`, `acceptCall`, `endCall`, `holdCall`, `sendDTMF:`.
- `transferAudioToComputer` and `transferAudioToPhone`.
- `currentCallList` (the HFP `AT+CLCC` command) and `sendATCommand:`.
- Delegate events for `isCallActive`, `callSetupMode`, `callHoldState`, `signalStrength`, and incoming caller ID.

The Bluetooth controller on this Mac (`BCM_4388C2`) lists `HFP` and `SCO` in its supported services. SCO is the Bluetooth voice link that carries call audio. Bluetooth was off during this test.

Risk: research found no public report that this class works end to end on macOS 12 or later. Many developers reported classic Bluetooth connection failures in macOS 12. A June 2025 forum thread about this class shows RFCOMM errors and has no answer. The Mac apps that used it (HandsFree 2, Phone Amego, PhoneCall) have no confirmed support for macOS 12 or later. Phase 1 of the plan tests this first.

Sources:

- https://developer.apple.com/forums/thread/694146?page=3
- https://developer.apple.com/forums/thread/786421

Since macOS 14, privacy controls (TCC) gate access to IOBluetooth. The bridge must run as a user app or a LaunchAgent, not as a root daemon. Its `Info.plist` must contain `NSBluetoothAlwaysUsageDescription`. If this key is missing, macOS stops the process. Source: https://developer.apple.com/forums/thread/738748

## 5. Bridge architecture

```
Android phone                                  Mac
+---------------------------+                  +----------------------------------+
| Native dialer and modem   |  Bluetooth HFP   | Mac bridge app (menu bar + agent)|
| (HFP Audio Gateway)       |<================>|  - IOBluetoothHandsFreeDevice    |
|                           |  control + SCO   |  - SCO audio -> Core Audio       |
|                           |  voice audio     |  - tel: link handler             |
| Companion app (optional)  |  Wi-Fi, TLS      |  - Notifications, call window    |
|  - contacts, call log     |<---------------->|  - Contacts lookup               |
|  - caller name, SMS       |  local network   |  - Own call history              |
+---------------------------+                  +----------------------------------+
                                                 Phone.app: not used for Android
```

This design matches Microsoft Phone Link on Windows. Section 10 compares the two.

| Operation | HFP only | With companion app |
|---|---|---|
| Incoming call detection | Yes (`RING`, `+CLIP`) | Yes, plus contact name and photo |
| Outgoing cellular call | Yes (`ATD`) | Yes (`TelecomManager.placeCall`) |
| Answer and reject | Yes (`ATA`, `AT+CHUP`) | Yes (`acceptRingingCall`, `endCall`) |
| Call-state sync | Yes (`+CIEV`, `+CLCC`) | Yes (`TelephonyCallback`) |
| Two-way cellular audio | Yes (SCO) | No. Android blocks it. |
| Mic and speaker routing | Core Audio (not tested: SCO must show as an audio device) | Not applicable |
| Call history and contacts | Partial (phone book over PBAP, not public on macOS) | Yes |

Android permissions for the companion app: `CALL_PHONE`, `ANSWER_PHONE_CALLS`, `READ_PHONE_STATE`, `READ_CALL_LOG`, `READ_CONTACTS`. If the app holds the default dialer role (`ROLE_DIALER`), it gets full call control through `InCallService`. But it then replaces the phone's own dialer.

## 6. Extend the Phone app, or build a separate app?

The Phone app cannot be extended. The only paths are private frameworks, private entitlements, and system binaries under System Integrity Protection. A separate app is necessary.

The closest native experience:

1. A native menu bar app with a background agent (a LaunchAgent).
2. The app registers for `tel:` links. The user confirms it as the default through `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`. Phone numbers in Contacts, Safari, Mail, and Calendar then start Android calls. This removes the `tel:` default from the Phone app. iPhone calls still work from inside the Phone app.
3. Incoming calls show as time-sensitive notifications with Answer and Decline actions, plus a small call window.
4. Optional: a Mac Catalyst version that uses `CXProvider` to get the system call interface. Test this before you commit to it.

## 7. Static analysis method

This study used read-only inspection of signed Apple binaries:

- `otool -L` for linked frameworks.
- `codesign -d --entitlements` for entitlements.
- `dyld_info -exports` for exported class names in the shared cache.
- `strings` on `callservicesd`.
- `plutil` on launch files and `Info.plist`.
- SDK headers and `.swiftinterface` files for API availability.

No binary was changed. No protection was turned off. A full decompile was not necessary for these conclusions.

## 8. Tests not done yet

- Bluetooth is off on the Mac. Hands-free behavior is not tested.
- `adb devices` showed no Android device. The phone is not tested.
- The Mac Catalyst CallKit path and Phone app Recents are not tested.

## 9. Proof-of-concept plan

### Phase 0: Prepare (you)

1. Turn on Bluetooth on the Mac.
2. On the Android phone, turn on Developer options and USB debugging.
3. Connect the phone with USB and accept the debugging prompt.
4. Pair the phone with the Mac in System Settings > Bluetooth.

### Phase 1: HFP spike on the Mac (1 to 2 days, go/no-go)

Write a small Swift command-line tool that uses `IOBluetoothHandsFreeDevice` with the paired phone. Pass criteria:

| Test | Pass when |
|---|---|
| Connect | The delegate reports `isServiceAvailable = 1`. |
| Incoming call | The tool logs `RING` and the caller number. |
| Answer and reject | `acceptCall` and `endCall` change the call on the phone. |
| Dial | `dialNumber:` starts a cellular call. |
| Call state | `isCallActive` and `callSetupMode` follow the phone. |
| Audio | After `transferAudioToComputer`, a new input and output device shows in `system_profiler SPAudioDataType`. Both sides hear speech. |
| Coexistence | AirPods still connect to the Mac during the test. |

If connect, control, or audio fails, use a separate Bluetooth stack that runs HFP in the Hands-Free role. Google Bumble and BTstack both support that role. Do not run them directly on macOS with a USB adapter. The BTstack README reports a kernel panic on macOS 26.0 to 26.4. The cause is libusb access to a USB Bluetooth controller. Source: https://github.com/bluekitchen/btstack/blob/master/port/libusb/README.md. Nobody reported a retest on macOS 27. Use one of these options:

1. A Linux virtual machine in UTM, with a CSR8510-class USB Bluetooth adapter passed through to it. This is the BTstack recommendation.
2. A small Linux computer, for example a Raspberry Pi, as an external hands-free unit. It sends call events and audio to the Mac over the local network.

Both options keep the built-in Bluetooth stack of macOS unchanged.

### Phase 2: Android companion spike (2 to 3 days)

1. Build a small Android app that reports call state with `TelephonyCallback`.
2. Add `placeCall`, `acceptRingingCall`, and `endCall`.
3. Find the Mac on the local network with Android NSD (mDNS).
4. Connect over TLS. Pair once with a short code.
5. Send contact name and call-log events to a Mac test client.
6. Make sure that events arrive in less than 500 ms on the same Wi-Fi.

### Phase 3: Mac integration spike (2 days)

1. Register a test app for `tel:` and set it as the default. Click numbers in Contacts and Safari.
2. Show incoming calls with `UNUserNotificationCenter` actions.
3. Build a Mac Catalyst test app with `CXProvider`. Report a fake incoming call. Record whether the system call interface shows, and whether the call shows in Phone app Recents.

### Phase 4: Decide

Pick the audio path (built-in HFP or external Linux hands-free unit) and the user interface path (native AppKit or Mac Catalyst with CallKit). Start the user interface only after this decision.

## 9a. Phase 1 results so far (2026-10-22)

The test app is `hfp-probe/` (HFP Probe). It runs as a signed app bundle with `NSBluetoothAlwaysUsageDescription`. A plain command-line tool got no Bluetooth access, as the research predicted.

| Test | Result |
|---|---|
| Bluetooth access from a user app on macOS 27 | Works after the user allows the prompt. |
| Pairing with the Android phone (Qualcomm chip) | Works. |
| Read the phone's services (SDP) | Works. Handsfree Gateway on RFCOMM channel 1, Headset Gateway on channel 2, Phonebook (PBAP) on channel 19. |
| `IOBluetoothHandsFreeDevice.connect` | Fails. No delegate event. The system log shows RFCOMM error 913. |
| Direct RFCOMM to channel 1 | Fails with the same error 913. |
| Direct RFCOMM to channel 12 (Object Push) | Works. MTU 990. |
| Publish a Hands-Free SDP record from the app | Works. macOS gives the app RFCOMM channel 8. |
| Phone shows "Phone calls" for the Mac after a new pairing | Yes. |
| Call channel after the new pairing | Still fails with error 913. The phone did not connect to channel 8. |

Error 913 is `OI_RFCOMM_REMOTE_REJECT` in the Open Interface Bluetooth stack that `bluetoothd` uses. Source: `oi_status.h` (for example https://github.com/bouffalolab/bl_iot_sdk/blob/master/components/network/ble/blestack/src/sbc/dec/oi_status.h). The status names in `/usr/sbin/bluetoothd` appear in the same order. The macOS log shows that the Mac completed its own security enforcement with no error before the rejection.

Conclusions so far:

1. Classic Bluetooth and RFCOMM work for third-party apps on macOS 27.
2. macOS does not block the call channel. The phone rejects it.
3. The reason for the rejection is on the phone.

Phone-side evidence (rea `list-adb-devices`, `inspect-adb-device`, `read-adb-logcat`, and `adb shell dumpsys bluetooth_manager`):

- The phone is a OnePlus 7T (HD1901), Android 12, OxygenOS build `Q.202303230244`. It uses the Oplus version of the Android Bluetooth stack.
- The phone bonds with the Mac as a dual-mode device.
- `HeadsetService` allows 5 hands-free devices. It has no state machine for the Mac. The call service never saw a connection from the Mac.
- During a retry, the phone opened the L2CAP channel for RFCOMM (PSM 3) and closed it about 0.3 seconds later. The Java call service logged nothing. The rejection happens in the native stack, before the call service.
- The phone logged `oplus_update_sm4_statue_after_ext_feat, the page is not contain ssp feat` for the Mac. This means that the phone records the Mac as a device without Secure Simple Pairing host support. The hands-free service needs a stronger security level than Object Push. This is the leading cause, but it is not proven.

The snoop log did not start on this OnePlus build. The bug report from rea `collect-adb-bugreport` has no `btsnoop_hci.log`. Its full log and a channel-by-channel test gave a clear result instead:

| Phone channel | Service | Result | Phone log |
|---|---|---|---|
| 1 | Hands-Free gateway (HFP) | Rejected | L2CAP opened, closed after 70 ms. No RFCOMM negotiation logged. |
| 2 | Headset gateway (HSP) | Accepted | `bta_ag_rfc_acp_open`, `HeadsetStateMachine` Connected, Mac set as the active call device. |
| 12 | Object Push | Accepted | `PORT_ParNegCnf incoming conn on dlci:24` |
| 19 | Phonebook (PBAP) | Accepted | Same security level as calls. |

Conclusions:

1. Security is not the cause. Phonebook and Headset need the same security level as hands-free, and both work.
2. The phone's call service accepts the Mac as a call device. Over HSP it made the Mac the active call audio device.
3. The phone advertises HFP on channel 1, but nothing on the phone answers there. A fresh SDP query shows the same table, with the Handsfree Gateway record listed twice.

The next test lets the phone start the HFP connection to the Mac. Car kits use this direction. HFP Probe listens for it on its published Hands-Free record. On each incoming connection, it runs the HFP setup commands.

Result: the phone does not start HFP to the Mac. The Mac's page in the phone's Bluetooth settings shows only "Contact sharing". It shows no "Phone calls" switch, also after a new pairing with the Hands-Free record published. Android needs HSP or HFP in the device's service list to show that switch. So the phone did not take the Mac's published Hands-Free record into its service list. The phone did fetch the Mac's services at 10:21:33 phone time, while the record was published. Neither device logged the new pairing, so the cause is not proven. Possible causes are a macOS limit on third-party SDP records and an OnePlus filter for computers.

Status of Phase 1: HFP control is blocked on this phone in both directions. HSP works now from the Mac side. HSP gives ring alerts, a single answer and hang-up button (`AT+CKPD=200`), and call audio. It does not give dialing or caller ID. The open question for both paths is SCO audio: macOS must accept the phone's voice link and show it as an audio device.

## 9b. Phase 1 call-audio test (2026-10-22)

Setup: HSP link from HFP Probe to phone channel 2. The phone showed the Mac as Connected and as the active call device. A second phone called the Android number.

| Step | Result | Evidence |
|---|---|---|
| Phone routes the incoming call to the Mac | Yes | `BluetoothInCallService ... route: BLUETOOTH`, `bta_ag_sco_open: open 1c:f6:4c:60:00:e0` |
| Phone opens the voice link (SCO) for in-band ringing | Yes, requested | `btm_send_connect_request: enhanced parameter list txbw=0x1f40` |
| Mac accepts the voice link | No | Mac: `SCO/eSCO reject (HOST_REJ_RESOURCES) ... SCO connect-accept declined`. Phone: `eSCO/SCO failed to open, no more fall back`, call audio back to the earpiece. |
| RING text reaches the Mac app | No | The raw HSP channel received no data. |
| Mac opens the voice link through `IOBluetoothHandsFreeDevice.connectSCO()` | No | The class first opens HFP channel 1. The phone rejects it with error 913, and no SCO request follows. |

Conclusions:

1. macOS 27 accepts a call voice link only for its own hands-free code. A third-party app with a raw RFCOMM link gets no SCO.
2. The only public way to get SCO is `IOBluetoothHandsFreeDevice`. That class needs an HFP service level connection, and this OnePlus 7T refuses HFP from the Mac.
3. With this phone, the built-in Mac Bluetooth path cannot carry call audio. Phase 1 result: no-go for this phone on built-in Bluetooth.

Next options, in order of cost:

1. Repeat Phase 1 with a different Android phone, for example a Pixel or a Samsung phone. If its HFP channel accepts the Mac, `IOBluetoothHandsFreeDevice` can handle both control and SCO.
2. Use an external hands-free unit that keeps the macOS Bluetooth stack out of the call path. Options are a Linux virtual machine in UTM with a USB Bluetooth adapter, or a Raspberry Pi. Bumble or BTstack runs HFP there and sends audio to the Mac over the network.

## 9c. Phase 1 HFP tests on the OnePlus 7T (2026-10-22)

Root cause of the channel 1 rejection: the OnePlus 7T advertises its HFP gateway on RFCOMM channel 1 in SDP, but the live server listens on channel 3. A scan of channels 1 to 30 found it. The phone logged `uuid=4383(0x111f)` and `conn_service = 1` for channel 3. This is a phone bug. Windows and car kits usually work around it because they find the channel again or the phone connects to them.

| Test | Result | Evidence |
|---|---|---|
| Manual HFP setup on channel 3 | Pass | `+BRSF: 3951`, `+CIND` values, `AT+CMER` and `AT+CLIP=1` both `OK` |
| `IOBluetoothHandsFreeDevice.connect` with an in-app channel remap 1 to 3 | Pass | `EVENT connected status=0`, live service, signal, and battery indicators |
| Incoming call detection | Pass | `EVENT callSetup=1 (incoming)` |
| Ring and caller ID (`RING`, `+CLIP`) | Fail | The phone sent neither. It plays the ring over SCO, and SCO failed. |
| Caller number through `currentCallList` (`AT+CLCC`) | Fail | The delegate returned an empty dictionary. |
| Answer from the Mac (`acceptCall`) | Pass | `callActive=1` within 1 second |
| Hang up from the Mac (`endCall`) | Pass | `callActive=0` within 1 second |
| Mac opens SCO (`connectSCO`) | Fail | `kIOReturnUnsupported` (0xE00002C7), "Failed to open SCO connection", no request sent |
| Phone opens SCO to the Mac | Fail | `SCO/eSCO reject (HOST_REJ_RESOURCES) ... SCO connect-accept declined`, also with Apple's class connected |
| Outgoing call (`dialNumber`) | Pass | Second attempt: `callSetup=2` (dialing) after 1 second, `callSetup=3` (ringing) after 2 seconds, `callActive=1` after 7 seconds, at the answer on the other phone. `endCall` ended it within 1 second. |
| Call list during an outgoing call (`AT+CLCC`) | Pass | `number = "+91XXXXXXXXXX"`, `direction = 0` (outgoing), `status = 0` (active), `type = 145` (international). During the incoming test, the same query returned an empty result. The reason is not known. One possibility is a withheld caller number. |

The channel remap is a method exchange inside HFP Probe only. It changes no macOS file or setting.

Phase 1 decision for macOS 27 with built-in Bluetooth:

1. Call control works: detection, dialing, answer, hang-up, and the call list. Caller ID for incoming calls is not confirmed yet.
2. Call audio does not work. macOS 27 declines SCO in both directions for a third-party app, also through Apple's public hands-free class. This matches the research finding that the old SCO audio driver is gone.
3. A Phone Link equivalent with Mac speakers and microphone needs an external hands-free unit for audio. The Mac app keeps HFP control, or the external unit takes both control and audio.

## 9d. Why macOS refuses call audio (static analysis, 2026-10-22)

A research agent read `/usr/sbin/bluetoothd` and the IOBluetooth framework on this Mac with rea, Hopper, `strings`, and the SDK headers. The analysis was read-only. No file, setting, or protection changed.

| Finding | Evidence |
|---|---|
| `bluetoothd` accepts an incoming SCO link only from the one device address that its own SCO setup code stored. In all other cases, it sends the HCI reject. | Function `sub_10018e1dc` holds the string `SCO/eSCO reject (HOST_REJ_RESOURCES) for %: IBconnectState=%d - SCO connect-accept declined`. The code at `0x10018e25c` to `0x10018e27c` compares the peer address against a global record at `0x100bab02d`. Only `OI_DEVMGR_ScoCreateConnection` (`sub_10018ce88`) writes that record. |
| A third-party app cannot set that record. | No client XPC message for classic SCO or HFP audio exists. The only audio messages are `CBMsgIdLEAudio*` (LE Audio). |
| The public app audio API for SCO is a stub. | SDK header `IOBluetoothUserLib.h`: `IOBluetoothAddSCOAudioDevice` is `DEPRECATED_IN_MAC_OS_X_VERSION_10_9_AND_LATER`, with the note "In 10.9 this is not needed and does nothing." No `IOBluetoothSCOAudioDriver` class remains. |
| The working audio pipeline is private. | `bluetoothd` sends audio through `bluetoothaudiod` and the Core Audio `BTHALAudioPlugin`. Clients need an entitlement and an allowlist entry: `Bypassing proc check for audio plugin clients via entitlement = %{public}s , allowList = %{public}s`. |
| macOS acts as an HFP Audio Gateway for headsets. The only built-in way to receive phone call audio is the iPhone Continuity relay. | Strings "Advertising HFP AG", "+XAPL=iPhone,15". Entitlements `com.apple.telephonyutilities.callservicesd` and `com.apple.private.carkit`. |

Conclusion: the refusal is by design. On macOS 27, no public API, documented method, or user setting gives a third-party app call audio from a Bluetooth phone. Every path through the built-in radio needs Apple-private entitlements or a security bypass, so this project uses none of them. Call audio on this Mac needs a second Bluetooth radio outside macOS control. `call-audio-setup.md` describes that setup.

## 10. Comparison with Windows Phone Link

Two research agents read Microsoft documentation, developer forums, and project pages. The Windows PC itself was not inspected, because this session has no remote access to it.

| Item | Windows Phone Link | This Mac design |
|---|---|---|
| Call audio | Bluetooth HFP over SCO. Microsoft says calls need Bluetooth (https://support.microsoft.com/en-us/help/4531605). | Bluetooth HFP over SCO |
| Computer role | Hands-Free unit. The phone shows as a "Hands-Free HF Audio" endpoint with the in-box "Microsoft Hands-Free Audio" driver (https://learn.microsoft.com/en-us/answers/questions/5956795/phone-link-initiates-iphone-calls-but-transfer-to). | Hands-Free unit through `IOBluetoothHandsFreeDevice` |
| Call control | HFP through the Windows `PhoneLine` APIs. The open-source MyPhone app dials and answers with no app on the phone (https://github.com/BestOwl/MyPhone). The exact split with the Android app is not confirmed. | HFP AT commands, plus the companion app as an option |
| Contacts and recent calls | Link to Windows Android app (https://www.samsung.com/us/support/answer/ANS10001476/) | Companion Android app |
| Network | Phone and PC on the same Wi-Fi network | Phone and Mac on the same Wi-Fi network |
| Operating system support | Windows ships a maintained HFP Hands-Free driver that exposes SCO as an audio device. | macOS has only an old public class with no recent proof that it works. |
| Third-party API | `PhoneLineTransportDevice` exists, but it needs a restricted capability. Reports say `RegisterApp` fails silently (https://learn.microsoft.com/en-us/answers/questions/6041632/phonelinetransportdevice-registerapp-has-no-effect). | `IOBluetoothHandsFreeDevice` is public and needs no special entitlement. |
| Known limits | No call relay to a Bluetooth headset. Other Bluetooth devices lower call quality. Keypad tones `*` and `#` do not work (https://support.microsoft.com/help/4531607). | Expect the same headset limit. Test it in Phase 1. |

The approach is the same as Phone Link. The difference is the operating system layer. Windows gives Phone Link a maintained hands-free driver. On macOS, the bridge app must supply that layer through an unproven API or through an external Linux hands-free unit. Phase 1 decides which one.

Phone Link does not use the Windows equivalent of the Phone app either. It is a separate app. This supports the conclusion in section 6.
