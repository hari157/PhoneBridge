# Call Audio on the Mac: USB Adapter Setup

This guide sets up two-way call audio for the OnePlus 7T on the Mac mini (macOS 27.0.1). It is a separate setup from the call-control tests in `android-calls-on-mac-report.md`.

## Why this setup is necessary

A Bluetooth phone call uses two links. The command link carries dial, answer, and hang up. The voice link (SCO) carries the sound. macOS 27 lets apps use the command link. It refuses the voice link for every third-party app. The Phase 1 tests show this (`SCO connect-accept declined`, `kIOReturnUnsupported`).

Static analysis of `/usr/sbin/bluetoothd` shows that this refusal is by design. The daemon accepts a voice link only for a call that its own audio code set up. The public app audio function `IOBluetoothAddSCOAudioDevice` "does nothing" since macOS 10.9. Section 9d of the report has the evidence. No setting or public API on macOS 27 changes this.

This setup adds a second Bluetooth radio that macOS does not control. A cheap USB Bluetooth adapter goes to a free Linux virtual machine (VM) in UTM. Linux accepts the voice link from the phone and sends the sound to the Mac over a private network inside the Mac.

```
OnePlus 7T --Bluetooth (HFP + SCO)--> USB adapter --> Linux VM in UTM
                                                       |  call control (D-Bus)
                                                       |  call audio (UDP, 16 kHz mono)
                                                       v
                                              Mac speakers and headset mic
```

Status: no public report confirms SCO through UTM USB passthrough. Step 7 is the go/no-go test. If it fails, use the Raspberry Pi option at the end.

## Cost

| Item | Price in India | Notes |
|---|---|---|
| TP-Link UB500 USB Bluetooth adapter (Realtek RTL8761BU) | about ₹509 to ₹599 | First choice. Linux needs the `rtl8761bu` firmware. |
| CSR8510 A10 USB adapter | about $3 to $7 (INR price not confirmed) | Backup. BTstack confirmed this adapter in a UTM Ubuntu VM. Cheap clones sometimes fail on new Linux kernels. |
| UTM, Debian, BlueZ, PipeWire, sox, ffmpeg | Free | |
| Wired or USB headset with a microphone, on the Mac | Already owned | The Mac mini has no built-in microphone. |

Total: about ₹600.

## What you need before you start

1. The USB adapter.
2. A headset with a microphone, connected to the Mac. Make sure that it shows in System Settings > Sound > Input.
3. Homebrew on the Mac.
4. About 15 GB of free disk space for the VM.
5. An administrator password for the Mac.

## Step 1: Keep macOS off the adapter

macOS switches to a plugged-in Bluetooth adapter by default. That moves all Mac Bluetooth onto the adapter. This setting tells macOS to keep using the built-in radio.

Warning: run this command yourself in Terminal. It changes a firmware setting and needs your administrator password.

```bash
sudo nvram bluetoothHostControllerSwitchBehavior=never
```

1. Restart the Mac.
2. Plug in the USB adapter.
3. In System Settings > Bluetooth, make sure that your Mac devices (keyboard, mouse) still work.

To undo this setting later, run the command below and restart.

```bash
sudo nvram -d bluetoothHostControllerSwitchBehavior
```

## Step 2: Install the Mac tools

```bash
brew install --cask utm
```

```bash
brew install sox ffmpeg
```

## Step 3: Create the Linux VM

1. Download the Debian 13 arm64 netinst ISO from debian.org.
2. In UTM, click Create a New Virtual Machine, then Virtualize, then Linux.
3. Select the Debian ISO.
4. Set memory to 2048 MB and CPU cores to 2.
5. Set the disk to 16 GB.
6. Before you start the VM, open its settings. In Input, set USB Support to USB 3.0 (xHCI).
7. In Network, keep Shared Network.
8. Start the VM and install Debian. Choose no desktop. Select SSH server.
9. Write down the user name that you create. This guide uses `pi`.

Debian 13 is necessary because the call features need PipeWire 1.4 or newer. Ubuntu 24.04 has PipeWire 1.0.5, which is too old. Ubuntu 26.04 also works.

Warning: save your work on the Mac before step 4. The BTstack project reports kernel panics on macOS 26.0 to 26.4 from software access to a USB Bluetooth controller. Nobody confirmed this risk for UTM on macOS 27.0.1.

## Step 4: Give the adapter to the VM

1. Start the VM.
2. In the UTM toolbar, click the USB icon.
3. Select the Bluetooth adapter.
4. In the VM, run the command below. Make sure that the adapter shows in the list.

```bash
lsusb
```

## Step 5: Install the Linux call software

In the VM:

```bash
sudo apt update
```

```bash
sudo apt install bluez pipewire pipewire-pulse wireplumber libspa-0.2-bluetooth pulseaudio-utils firmware-realtek netcat-openbsd
```

Let the PipeWire user services run without a desktop login:

```bash
sudo loginctl enable-linger pi
```

Turn on the hands-free role and wideband speech. Create the file `~/.config/wireplumber/wireplumber.conf.d/51-bluez-hf.conf` with this content:

```
monitor.bluez.properties = {
  bluez5.roles = [ hfp_hf hsp_hs a2dp_sink ]
  bluez5.hfphsp-backend = "native"
  bluez5.enable-msbc = true
}
```

Restart the services and the VM:

```bash
sudo reboot
```

After the restart, make sure that PipeWire is version 1.4 or newer:

```bash
pipewire --version
```

## Step 6: Pair the phone with the VM

Quit HFP Probe on the Mac first. Otherwise the phone sends call audio to the Mac, and the Mac refuses it.

In the VM:

```bash
bluetoothctl
```

At the `[bluetooth]#` prompt, type each command:

```
power on
agent on
default-agent
pairable on
discoverable on
```

1. On the phone, open Settings > Bluetooth and pair with the VM. Its name starts with the VM host name.
2. Accept the code on both screens.
3. In `bluetoothctl`, type `trust` followed by the phone address, for example `trust AA:BB:CC:DD:EE:FF`.
4. On the phone, open the gear next to the VM and turn on Phone calls.
5. Start the connection from the phone. Tap the VM name in the phone's Bluetooth list.

Start the connection from the phone. The OnePlus 7T advertises its hands-free service on the wrong channel (1 instead of 3). When the phone connects, it uses the VM's own record and avoids that bug.

## Step 7: Go/no-go test for call audio

Find the Bluetooth sound devices in the VM:

```bash
pactl list short sources | grep bluez
```

```bash
pactl list short sinks | grep bluez
```

1. Call the OnePlus from another phone.
2. Answer on the OnePlus.
3. Run the two `pactl` commands again during the call.

Pass: a `bluez_input` source and a `bluez_output` sink show during the call.

Fail: no `bluez` devices show, or they show but the sound is silent or broken. If it fails, use the Raspberry Pi option at the end.

## Step 8: Send the call audio to the Mac

Find the IP addresses. In the VM, run `ip addr` and note the address that starts with `192.168.64`. The Mac is usually `192.168.64.1` on the UTM shared network.

On the Mac, list the microphones and note the number of your headset:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

Start four streams during a call. Replace `VM_IP`, `MIC_NUMBER`, `<bluez_input>`, and `<bluez_output>` with your values.

Mac, receive the caller's voice:

```bash
nc -ul 5000 | play -t raw -r 16000 -e signed -b 16 -c 1 -
```

VM, send the caller's voice to the Mac:

```bash
parec --raw --format=s16le --rate=16000 --channels=1 -d <bluez_input> | nc -u 192.168.64.1 5000
```

VM, receive your voice from the Mac:

```bash
nc -lu 5001 | pacat --raw --format=s16le --rate=16000 --channels=1 -d <bluez_output>
```

Mac, send your voice to the VM:

```bash
ffmpeg -f avfoundation -i ":MIC_NUMBER" -ac 1 -ar 16000 -f s16le udp://VM_IP:5001
```

Pass: you hear the caller through the Mac, and the caller hears you through the Mac headset.

Expected delay is about 100 to 200 ms. This value is an estimate and is not measured.

## Step 9: Call control from the Mac

With this setup, the VM holds the hands-free link. Call control moves to the VM. The phone then sees one hands-free device, which is more reliable than two.

PipeWire 1.4 and newer has a Telephony D-Bus service for Dial, Answer, and Hangup. List its objects in the VM:

```bash
busctl --user tree org.pipewire.Telephony
```

Show the methods of an object from that list, for example:

```bash
busctl --user introspect org.pipewire.Telephony /org/pipewire/Telephony/ag0
```

Answer an incoming call (the object path comes from the tree command):

```bash
busctl --user call org.pipewire.Telephony /org/pipewire/Telephony/ag0/call0 org.pipewire.Telephony.Call1 Answer
```

The Mac app sends these commands to the VM over SSH. This replaces the HFP Probe control link for daily use.

## Tests

| Test | Pass when |
|---|---|
| Adapter in VM | `lsusb` in the VM shows the adapter. |
| Pairing | The phone shows Phone calls for the VM. |
| Voice link | `bluez_input` and `bluez_output` show during a call. |
| Caller's voice on the Mac | You hear the caller through the Mac. |
| Your voice to the caller | The caller hears you through the Mac headset. |
| Answer from the Mac | The SSH `Answer` command answers the call. |
| Dial from the Mac | The `Dial` method starts a call. |
| Hang up from the Mac | The `Hangup` method ends the call. |
| Mac stability | No restart or freeze during 3 test calls. |

## Fallbacks

1. Apple Virtualization backend. UTM 5.0.6 and newer supports USB passthrough with this backend on macOS 27. Assign the adapter under Virtual Machine Accessories. Isochronous USB support, which the voice link needs, is not confirmed.
2. oFono with PipeWire in the VM, in place of the PipeWire native backend.
3. Google Bumble in the VM. It can open channel 3 directly, but you must write the audio handling.
4. Raspberry Pi Zero 2 W (about ₹1,500 to ₹2,000) with the same USB adapter and the same software from steps 5 to 9. This avoids UTM passthrough and the macOS kernel panic risk. The Pi sends audio to the Mac over your home network.

## Sources

- BTstack libusb README (UTM with CSR8510, macOS 26 warning): https://github.com/bluekitchen/btstack/blob/master/port/libusb/README.md
- UTM USB sharing: https://docs.getutm.app/guest-support/sharing/usb/
- UTM input page (USB 3.0 controller): https://docs.getutm.app/settings-qemu/input/
- PipeWire native HFP backend: https://github.com/PipeWire/pipewire/blob/master/spa/plugins/bluez5/backend-native.c
- PipeWire Telephony API: https://github.com/PipeWire/pipewire/blob/master/spa/plugins/bluez5/README-Telephony.md
- WirePlumber Bluetooth guide: https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/bluetooth.html
- TP-Link UB500 on Linux: https://wiki.gentoo.org/wiki/UB500
