# Installing the iPhone app – without a Mac, for free

Apple only allows apps outside the App Store if they are signed. For this you need **no Mac
and no paid developer account**: the app is built for free in the cloud
(GitHub Actions) and brought to the iPhone on Windows with **Sideloadly** and your **regular Apple ID**.

| What | Cost |
|---|---|
| Building the app (GitHub Actions, public repo) | free |
| Sideloadly | free |
| Apple ID (no developer program needed) | free |
| Limitation | The app has to be re-signed every **7 days** (Sideloadly can do this automatically) |

## 1. Download the IPA

- **Simple:** On the [Releases page](https://github.com/MoinMornhart/RayBanClaude/releases/latest)
  download the file `RayBanClaude.ipa`. For verification, `RayBanClaude.ipa.sha256` sits next to it –
  on Windows compare with: `Get-FileHash RayBanClaude.ipa -Algorithm SHA256`
- **Latest state:** [Actions → "Build iOS app"](https://github.com/MoinMornhart/RayBanClaude/actions/workflows/ios-build.yml)
  → open the latest green run → at the bottom under *Artifacts* download `RayBanClaude-ipa` and unzip it
  (you have to be signed in to GitHub for this).

## 2. Set up Sideloadly (Windows)

1. Install **iTunes and iCloud** from apple.com – the versions *from the Apple website*,
   not from the Microsoft Store (Sideloadly needs their drivers).
2. Download and install **Sideloadly** from <https://sideloadly.io>.
3. Connect the iPhone with a **USB cable** and tap "Trust This Computer" on the iPhone.

## 3. App onto the iPhone

1. Open Sideloadly and drag `RayBanClaude.ipa` into the window.
2. Enter your **Apple ID** → **Start**. (The password only goes to Apple; if you want to be careful, use
   an app-specific password or a secondary Apple ID.)
3. If Sideloadly reports that the bundle ID is taken: under *Advanced Options* choose your own
   bundle ID, e.g. `com.yourname.raybanclaude` (**without a hyphen**).
4. On the iPhone:
   - *Settings → General → VPN & Device Management →* your Apple ID → **Trust**
   - *Settings → Privacy & Security → Developer Mode →* **on** (the iPhone restarts)

## 4. Refresh every 7 days

With a free Apple ID the signature expires after 7 days. In Sideloadly, enable
"Automatic Refresh" (PC and iPhone on the same Wi-Fi) – then it happens on its own.
Alternatively just repeat step 3; settings and pairing are kept.

> With a paid Apple Developer account (€99/year) the signature lasts a year.
> Alternatives to Sideloadly: AltStore or SideStore.

## 5. Pair with the PC

1. Start **"RayBan Claude"** on the PC (desktop icon from the [Windows installer](https://github.com/MoinMornhart/RayBanClaude/releases/latest/download/RayBanClaude-Setup.exe) or `start.cmd`) → the dashboard opens.
2. With the iPhone on the same Wi-Fi, point the regular **Camera app** at the QR code.
3. "Open in RayBan Claude" → confirm **Pair**. Done.

For **on the go via your Claude subscription**: set up Tailscale on PC and iPhone beforehand – then the
on-the-go address is included in the QR code automatically ([guide](../README.md#-on-the-go-with-your-claude-subscription)).

## Connecting the Ray-Ban Meta Gen 2

1. Meta AI app → Settings → your glasses → **Developer mode** on, restart the glasses.
2. In RayBan Claude: Settings → **Connect glasses via Meta AI** → allow in the Meta AI app.
3. Tap **Glasses** at the bottom right and confirm the camera permission.

In developer mode you need **no** Meta app ID of your own. Only if you want to distribute the app to others via
Meta release channels do you enter it in `ios/Secrets.xcconfig`.
