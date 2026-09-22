import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const envDir = join(root, 'environments');
const activePath = join(envDir, 'active');
const target = (process.argv[2] ?? 'status').toLowerCase();

const known = new Set(['local', 'uat', 'status']);
if (!known.has(target)) {
  console.error('Usage: node scripts/switch-env.mjs <local|uat|status>');
  process.exit(1);
}

mkdirSync(envDir, { recursive: true });

function readActive() {
  if (!existsSync(activePath)) return null;
  return readFileSync(activePath, 'utf8').trim().toLowerCase() || null;
}

function envFile(name) {
  return join(envDir, `${name}.env`);
}

function exampleFile(name) {
  return join(envDir, `${name}.env.example`);
}

function ensureEnvFile(name) {
  const dest = envFile(name);
  if (existsSync(dest)) return dest;
  const example = exampleFile(name);
  if (!existsSync(example)) {
    console.error(`Missing ${example}. Restore it from the repo and retry.`);
    process.exit(1);
  }
  copyFileSync(example, dest);
  console.warn(`Created ${dest} from example. Fill in real secrets before use.`);
  return dest;
}

if (target === 'status') {
  const active = readActive();
  const hasDotEnv = existsSync(join(root, '.env'));
  console.log(`Active environment: ${active ?? '(none)'}`);
  console.log(`Root .env: ${hasDotEnv ? 'present' : 'missing'}`);
  for (const name of ['local', 'uat']) {
    console.log(`environments/${name}.env: ${existsSync(envFile(name)) ? 'present' : 'missing'}`);
  }
  process.exit(0);
}

const source = ensureEnvFile(target);
copyFileSync(source, join(root, '.env'));
writeFileSync(activePath, `${target}\n`, 'utf8');

const contents = readFileSync(source, 'utf8');
const appUrl = contents.match(/^MYDOX_APP_URL=(.*)$/m)?.[1]?.trim() || '(not set)';
console.log(`Switched to ${target}.`);
console.log(`Copied environments/${target}.env → .env`);
console.log(`MYDOX_APP_URL=${appUrl}`);
if (target === 'local') {
  console.log('Next: npm run dev  (then android:apk:local / android:apk:local:usb)');
} else {
  console.log('Next: npm run android:apk:uat  (APK loads the hosted UAT URL)');
}
