<div align="center">
   <img width="217" height="217" src="/assets/StikDebug.png" alt="Logo">
</div>

<div align="center">
  <h1><b>StikDebug</b></h1>
  <p><i>An on-device debugger/JIT enabler for iOS versions 17.4+ powered by <a href="https://github.com/jkcoxson/idevice">idevice</a>.</i></p>
</div>

<h6 align="center">
  <a href="https://discord.gg/ZnNcrRT3M8">
    <img src="https://img.shields.io/badge/Discord-join%20us-7289DA?logo=discord&logoColor=white&style=for-the-badge&labelColor=23272A" />
  </a>
  <a href="https://github.com/StikDebug/StikDebug/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/StikDebug/StikDebug?label=License&color=5865F2&style=for-the-badge&labelColor=23272A" />
  </a>
  <a href="https://github.com/StikDebug/StikDebug/stargazers">
    <img src="https://img.shields.io/github/stars/StikDebug/StikDebug?label=Stars&color=FEE75C&style=for-the-badge&labelColor=23272A" />
  </a>
  <a href="https://github.com/StikDebug/StikDebug/releases">
    <img src="https://img.shields.io/github/v/release/StikDebug/StikDebug?label=Latest&color=00BFFF&style=for-the-badge&labelColor=23272A" />
  </a>
  <br />
</h6>

## This fork: iOS 27 developer images

This fork addresses the developer disk image failures reported in
[upstream #464](https://github.com/StikDebug/StikDebug/issues/464) and
[#465](https://github.com/StikDebug/StikDebug/issues/465). The upstream download mirror
can lag behind new iOS releases and device models. The fork's build workflow extracts
the personalized DDI from Xcode 27 and includes it in the IPA.

- Downloads are installed as complete sets after checking the image and trust cache against the manifest's SHA-384 digests.
- Cached images are checked for updates once per launch. Offline launches retain a verified cached image.
- Newer bundled images are preferred over older mirror images, including release candidates versus earlier betas.
- **Settings → Advanced → Import DDI Folder** accepts an exported DDI folder or Xcode's `iOS_DDI/Restore` folder. Imported images stay selected across launches.
- A `BadBuildManifest` failure triggers at most one automatic refresh and retry. If no compatible image is available, the error explains how to import one.

**Validation status:** automated storage, integrity, import, and export tests are included.
Physical-device DDI mounting and JIT on iOS 27 still require verification; an image
must support the particular device, and the target app must support iOS 27 JIT.

## Features
- **JIT:** Enable Just In Time compilation for sideloaded apps that have the `get-task-allow` entitlement.
- **App Launching:** Launch every app installed on your device.
- **Console:** Live app and system logs.
- **Scripts:** Manage automation scripts (mainly used for iOS 26 JIT). 
- **App Expiry:** See when apps will expire and install/remove profiles.
- **Device Info:** View detailed device metadata.
- **Processes:** Inspect running apps/processes and terminate them.
- **Location Simulator:** Simulate the GPS location of your device.

## Download
Open this fork's [Build Debug IPA workflow](https://github.com/zeuzmakessoftware/StikDebug/actions/workflows/build_ipa.yml),
select a successful run, and download the `StikDebug-<commit>.ipa` artifact. It is
unsigned; install it with your usual signing/sideloading tool. The separate
`StikDebug-Xcode27-DDI` artifact contains the importable image folder.

Upstream StikDebug releases do not include this fork's changes.

## Compatibility

| iOS Version              | Status               | Notes                                                                 |
|--------------------------|----------------------|-----------------------------------------------------------------------|
| 1.0 – 17.3.X             | Not supported        | Uses Different Connection Protocols                                   |
| 17.4 – 18.x              | Fully supported      | Stable                                                                |
| 26.x                    | Upstream support     | Limited app availability; developers need to update their apps.        |
| 27.x                    | Device testing needed | This fork supplies an Xcode 27 DDI and image update/import recovery.   |

### Import a current Xcode image

1. Download and unzip `StikDebug-Xcode27-DDI` from a successful build, or export from a Mac with the latest Xcode 27 installed and initialized:

   ```bash
   python3 scripts/export_ddi.py --output /tmp/StikDebug-DDI
   ```

   To choose an expanded image explicitly, add `--source /Library/Developer/DeveloperDiskImages/iOS_DDI/Restore`.
   The exporter rejects pre-Xcode-27 builds by default and verifies payload digests.
2. Transfer the entire output folder to Files on the iPhone or iPad.
3. In StikDebug, open **Settings → Advanced → Import DDI Folder** and choose that folder.
4. Connect the loopback VPN and retry. If a DDI was already mounted, reboot the device first so it can mount the replacement.

Keep `BuildManifest.plist`, `Image.dmg`, and `Image.dmg.trustcache` together. A pairing
file is separate from the developer image. If the newest image still produces
`BadBuildManifest`, collect the device model, iOS version, DDI build, and full error
for further investigation; repeated pairing imports cannot add a missing build identity.

## How to Enable JIT

StikDebug enables **JIT** for sideloaded apps on iOS 17.4+ without needing a computer after the initial pairing setup.

### Requirements
- StikDebug installed (via AltSource, direct .ipa, or self-built)
- A valid **pairing file** (.plist / .mobiledevicepairing) for your device
- SideStore / AltStore / similar sideload tool (for app refreshing)
- A loopback VPN such as [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)

### Steps
1. **Obtain a pairing file**  
   - Detailed guide: [Pairing File Instructions](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md) (or ask in Discord).

2. **Set up VPN**  
   - Launch LocalDevVPN and enable the VPN.

4. **Enable JIT for an app**  
   - Launch StikDebug and tapp the `Enable JIT` button.
   - Select your sideloaded app from the list in StikDebug.  

**Troubleshooting**  
- "Connection dropped" or loopback errors → Check iOS version compatibility / beta warnings.  
- Heartbeat errors → Ensure that the VPN is on and that you are connecected to Wi-Fi. It may be a pairing file issue.
- Pairing file issues → Replace file with device unlocked & trusted.  
- Still stuck? Join the [Discord](https://discord.gg/ZnNcrRT3M8) with logs/screenshots.

<!-- 
## Screenshots

<div align="center">
  <img src="screenshots/pairing-import.png" width="320" alt="Pairing file import screen">
  <img src="screenshots/app-list.png" width="320" alt="Sideloaded apps list">
  <img src="screenshots/jit-enabled.png" width="320" alt="JIT successfully enabled">
  <img src="screenshots/processes.png" width="320" alt="Process management tab">
</div>

(Add images to a /screenshots/ folder in the repo and uncomment when ready.)
-->

## Building from Source

> [!IMPORTANT]
> **Integrating StikDebug or StikJIT into your own project?**  
> See the [StikJIT Integration Guide](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md) for integration instructions.

### Requirements
- macOS (latest recommended)
- Xcode 27 for this fork's bundled developer image workflow
- iOS device on iOS 17.4+ (for testing)
- Git
- Basic Xcode/Swift knowledge

### Steps
1. **Clone the repo**
   ```bash
   git clone https://github.com/zeuzmakessoftware/StikDebug.git
   cd StikDebug
   ```

2. **Open in Xcode**
   - Launch Xcode
   - Open `StikDebug.xcodeproj`

3. **Configure signing**
   - Select the **StikDebug** target
   - Go to **Signing & Capabilities**
   - Sign in with your Apple ID (free or paid developer account)
   - Set a unique **Bundle Identifier** (e.g., `com.yourname.StikDebug`)

4. **Build & install**
   - Select your connected device
   - Press **Cmd + R** (or Product → Run)
   - Trust the certificate on device: Settings → General → VPN & Device Management

After install, follow the JIT setup steps above (pairing import, etc.).

The GitHub workflow adds `BundledDDI` to the unsigned app during IPA packaging.
For a direct Xcode build, import an exported image using Settings after installation.
The app's deployment target remains iOS 17.4.

### Automated checks

```bash
swift test
python3 -m unittest discover -s Tests -p 'test_*.py'
```

The Swift package tests the same DDI service files used by the app, independently
of its device-only native library. The workflow also archives the full iOS app
with Xcode 27. Neither check substitutes for mounting a DDI and enabling JIT on a
physical device.

## Contributing

Thank you for your interest in contributing to this project. Contributions of all kinds are welcome.

### Reporting Bugs
If you discover a bug, please open an issue and include:
- A clear and descriptive title
- Steps to reproduce the issue
- Expected behavior vs. actual behavior
- Relevant logs, screenshots, or environment details (iOS version, device model, etc.)

### Suggesting Features
To propose a new feature, open a feature request issue and provide:
- A clear description of the feature
- The problem it solves or the use case it addresses
- Any relevant examples or implementation ideas

### Code Contributions (Best Practices)
- Follow normal Swift and SwiftUI style.
- Write clear and easy to understand code.
- Keep your changes consistent with how the project is already set up.
- Make sure everything builds and works without errors.

We appreciate your time and effort in helping improve this project.

## Code Help
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/StikDebug/stikdebug)
## License
StikDebug is licensed under **AGPL-3.0**. See [`LICENSE`](LICENSE) for details.
