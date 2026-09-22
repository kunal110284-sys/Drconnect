import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const modeArg = (process.argv[2] ?? 'local').toLowerCase();
const aliases = { emulator: 'local', preview: 'local' };
const mode = aliases[modeArg] ?? modeArg;
const allowed = new Set(['local', 'usb', 'uat']);
if (!allowed.has(mode)) {
  console.error('Usage: node scripts/android-preview.mjs <local|usb|uat> [--build]');
  console.error('  local  → emulator APK at http://10.0.2.2:8081 (requires npm run dev)');
  console.error('  usb    → USB phone APK at http://127.0.0.1:8081 (requires npm run dev + adb reverse)');
  console.error('  uat    → APK at hosted UAT URL (default https://drconnect-uat.vercel.app)');
  process.exit(1);
}

function readAppUrlFromEnvFiles() {
  for (const relative of ['.env', 'environments/uat.env', 'environments/local.env']) {
    const path = join(root, relative);
    if (!existsSync(path)) continue;
    const match = readFileSync(path, 'utf8').match(/^MYDOX_APP_URL=(.*)$/m);
    const value = match?.[1]?.trim();
    if (value) return value;
  }
  return process.env.MYDOX_APP_URL?.trim() || 'https://drconnect-uat.vercel.app';
}

const uatUrl = readAppUrlFromEnvFiles();

if (mode === 'local' || mode === 'usb') {
  try {
    const response = await fetch('http://127.0.0.1:8081/auth', { signal: AbortSignal.timeout(10000) });
    if (!response.ok) throw Error(`Server returned HTTP ${response.status}.`);
    await response.body?.cancel();
  } catch {
    console.error('MyDox is not available at http://127.0.0.1:8081. Keep npm run env:use:local && npm run dev running, then retry.');
    process.exit(1);
  }
} else {
  try {
    const response = await fetch(new URL('/auth', uatUrl), { signal: AbortSignal.timeout(15000) });
    if (!response.ok) {
      console.warn(`Warning: UAT ${uatUrl}/auth returned HTTP ${response.status}. Continuing APK build.`);
    }
    await response.body?.cancel();
  } catch (error) {
    console.warn(`Warning: could not reach UAT ${uatUrl} (${error instanceof Error ? error.message : error}). Continuing APK build.`);
  }
}

const env = {
  ...process.env,
  MYDOX_ANDROID_TARGET: mode === 'uat' ? 'uat' : 'local',
  MYDOX_ANDROID_PREVIEW: mode,
  MYDOX_APP_URL: uatUrl,
};

// A source archive has no generated assets. Capacitor needs this directory
// even when the preview loads a remote/local server instead of bundled HTML.
mkdirSync(join(root, 'android', 'app', 'src', 'main', 'assets', 'public'), { recursive: true });
execFileSync(process.execPath, ['node_modules/@capacitor/cli/bin/capacitor', 'sync', 'android'], {
  cwd: root, env, stdio: 'inherit', windowsHide: true,
});

const sdk = env.ANDROID_HOME || env.ANDROID_SDK_ROOT ||
  (process.platform === 'win32' && env.LOCALAPPDATA ? join(env.LOCALAPPDATA, 'Android', 'Sdk') : null);
if (sdk && existsSync(sdk)) {
  env.ANDROID_HOME = sdk;
  const properties = join(root, 'android', 'local.properties');
  if (!existsSync(properties)) writeFileSync(properties, `sdk.dir=${sdk.replaceAll('\\', '/')}\n`);
}

const defaultApk = join(root, 'android', 'app', 'build', 'outputs', 'apk', 'debug', 'app-debug.apk');
const labeledApk = join(root, 'android', 'app', 'build', 'outputs', 'apk', 'debug', `app-debug-${mode}.apk`);

if (process.argv.includes('--build')) {
  const options = { cwd: join(root, 'android'), env, stdio: 'inherit', windowsHide: true };
  if (process.platform === 'win32') {
    execFileSync('powershell.exe', ['-NoProfile', '-Command', '& ./gradlew.bat :app:assembleDebug --no-daemon; exit $LASTEXITCODE'], options);
  } else {
    execFileSync('./gradlew', [':app:assembleDebug', '--no-daemon'], options);
  }
  if (existsSync(defaultApk)) {
    copyFileSync(defaultApk, labeledApk);
    console.log(`APK: android/app/build/outputs/apk/debug/app-debug-${mode}.apk`);
    console.log('Also: android/app/build/outputs/apk/debug/app-debug.apk');
  } else {
    console.error('Gradle finished but app-debug.apk was not found.');
    process.exit(1);
  }
}

const serverUrl =
  mode === 'uat' ? uatUrl :
  mode === 'usb' ? 'http://127.0.0.1:8081' :
  'http://10.0.2.2:8081';

console.log(`MyDox ${mode} Android target prepared → ${serverUrl}`);
if (mode === 'local') console.log('Keep npm run dev running. Use an Android emulator.');
if (mode === 'usb') console.log('On your authorized device, run: adb -s <device-id> reverse tcp:8081 tcp:8081');
if (mode === 'uat') console.log('This APK loads hosted UAT; local npm run dev is not required.');
