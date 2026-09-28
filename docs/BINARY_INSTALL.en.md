# Codex iPhone Relay v1.5.1 installation

[简体中文](BINARY_INSTALL.md) | **English**

## Mac

Requires Apple Silicon (M1 or later), macOS 13+, the Codex desktop app, and an existing Responses API configuration.

1. Extract `codex-relay-v1.5.1-macos-arm64.zip`.
2. Open `Install.command` and enter your configuration directory, such as `~/.codex-2` or `~/.codex`.
3. Open the installed **Codex 3** app.

Python and Xcode are not required. Apps are installed in `~/Applications` by default; an existing installation in `/Applications` is updated there when writable. Your source configuration is preserved. The installer prompts are in Chinese; the only prompt asks for your API configuration directory.

The package is not notarized. If macOS blocks it, try opening `CodexRelaySetup`, then allow that program in **System Settings → Privacy & Security → Open Anyway** and retry the installer.

## iPhone

Download `codex-relay-v1.5.1-ios-unsigned.ipa`. Requires iOS 16+. The IPA is already compiled and must be signed for your device.

**Without a development certificate:** Follow the [AltStore Classic macOS guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos). Keep AltServer running and your iPhone connected to the Mac. On iPhone, open **AltStore → My Apps → +** and select the IPA. Enable Developer Mode and trust the developer when prompted. Free-account signatures normally expire after 7 days and must be refreshed.

**With a development certificate:** Import your certificate and private key into Keychain. Use `Sign-iPhone.command`, or run the command below. The provisioning profile must include your iPhone. Install the signed IPA with Apple Configurator.

```bash
./CodexRelaySetup iphone \
  --ipa ../codex-relay-v1.5.1-ios-unsigned.ipa \
  --profile /path/to/your.mobileprovision \
  --output ~/Desktop/BluetoothRelay-signed.ipa
```

Add `--device 'device name or identifier'` to install after signing; this option requires full Xcode. Neither signing method requires a source build. Initial setup and signature renewal require internet access; the Mac can stay offline during normal relay use.

## Pair and use

1. On Mac, click **配对 iPhone** (Pair iPhone). On iPhone, open **配对 Mac → 扫描二维码** (Pair Mac → Scan QR code) and save the pairing.
2. Select **Type-C / 蓝牙 / Type-C + 蓝牙** (USB-C / Bluetooth / both) on both devices, then tap **开始转发** (Start relay) on iPhone.
3. Wait for a connection and **已同步** (Synced) API settings, then send a prompt in Codex 3.

Edit API settings with the gear button on either device; the most recently saved settings take effect by default. Your iPhone must be able to reach the API. Personal Hotspot is not required; only API requests are relayed. Quit the Mac relay app before updating, then restart forwarding on iPhone afterward.

Background execution is limited by iOS. Windows and Intel Mac installers are not available.
