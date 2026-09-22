import type { CapacitorConfig } from '@capacitor/cli';

/**
 * Android WebView server target:
 * - local (emulator): http://10.0.2.2:8081 → PC vite via emulator loopback
 * - usb:              http://127.0.0.1:8081 → PC vite via adb reverse
 * - uat:              MYDOX_APP_URL (hosted Vercel UAT)
 *
 * Set by scripts/android-preview.mjs via MYDOX_ANDROID_PREVIEW / MYDOX_APP_URL.
 */
const preview = (process.env.MYDOX_ANDROID_PREVIEW ?? '').toLowerCase();
const target = (process.env.MYDOX_ANDROID_TARGET ?? (preview === 'uat' ? 'uat' : preview ? 'local' : '')).toLowerCase();
const uatUrl = (process.env.MYDOX_APP_URL ?? 'https://drconnect-uat.vercel.app').replace(/\/$/, '');

function serverBlock(): CapacitorConfig['server'] {
  const base = { androidScheme: 'https' as const };
  if (target === 'uat' || preview === 'uat') {
    return { ...base, url: uatUrl, cleartext: false };
  }
  if (preview === 'usb') {
    return { ...base, url: 'http://127.0.0.1:8081', cleartext: true };
  }
  if (preview === 'local' || preview === 'emulator' || target === 'local') {
    return { ...base, url: 'http://10.0.2.2:8081', cleartext: true };
  }
  return base;
}

const config: CapacitorConfig = {
  appId: 'com.mydox.app',
  appName: 'MyDox',
  // TanStack Start build output folder
  webDir: '.output/public',
  server: serverBlock(),
};

export default config;
