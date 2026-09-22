# MyDox in Android Studio

Open this repository's **android** folder as a project. It is the MyDox Capacitor/Gradle project, with application ID `com.mydox.app` and launcher name **MyDox**. Select the `app` run configuration and the `debug` build variant.

## Local vs UAT

| Target | Command | WebView URL | Needs `npm run dev`? |
|--------|---------|-------------|----------------------|
| **Local** (emulator) | `npm run android:apk:local` | `http://10.0.2.2:8081` | Yes |
| **Local** (USB phone) | `npm run android:apk:local:usb` | `http://127.0.0.1:8081` + `adb reverse` | Yes |
| **UAT** (hosted) | `npm run android:apk:uat` | `MYDOX_APP_URL` (default `https://drconnect-uat.vercel.app`) | No |

Switch the root `.env` profile (Supabase keys + `MYDOX_APP_URL`):

```powershell
npm run env:use:local
npm run env:use:uat
npm run env:status
```

Profiles live in `environments/local.env` and `environments/uat.env` (gitignored). Start from the committed `*.env.example` files.

## Build the local emulator APK

Keep the server running in one terminal:

```powershell
npm ci
npm run env:use:local
npm run dev
```

In another terminal:

```powershell
npm run android:apk:local
npm run cap:open:android
```

Output:

- `android/app/build/outputs/apk/debug/app-debug-local.apk`
- `android/app/build/outputs/apk/debug/app-debug.apk` (same build)

The emulator preview loads `http://10.0.2.2:8081`, which connects to this PC. Keep the server running.

## Optional USB phone (local)

```powershell
npm run android:apk:local:usb
adb devices
adb -s <your-device-id> reverse tcp:8081 tcp:8081
adb -s <your-device-id> install -r android/app/build/outputs/apk/debug/app-debug-usb.apk
```

## Build the UAT APK

No local Vite server required. The APK WebView loads the hosted UAT URL from `MYDOX_APP_URL` in `environments/uat.env`.

```powershell
npm run env:use:uat
npm run android:apk:uat
```

Output: `android/app/build/outputs/apk/debug/app-debug-uat.apk`.

Add `https://drconnect-uat.vercel.app` (and redirects) in Supabase Auth allowlists before testing login on device.

## Release status

The debug APK builds and its package identity and signature have been checked. It uses MyDox artwork and the native splash screen. It is signed with the development key.

TanStack Start uses a running server and currently emits no standalone client `index.html`. A production release needs the hosted server/API and a supported bundled mobile frontend, production Auth redirects, feature testing, and the owner's signing key. Release builds reject local-server preview configuration (`validateReleaseWebApp`). Cleartext traffic is enabled only for local debug targets.

Only client assets are copied into the APK. Server source, the staging privileged key, and the local `.env` stay on the PC.

References: [Capacitor configuration](https://capacitorjs.com/docs/v7/config), [Android command-line builds](https://developer.android.com/build/building-cmdline).
