#!/usr/bin/env node
/**
 * Apply a staging SQL migration to UAT.
 *
 * Preferred: DATABASE_URL or SUPABASE_DB_PASSWORD (Postgres pooler).
 * Alternate: SUPABASE_ACCESS_TOKEN (Supabase Management API database query).
 *
 * Usage:
 *   node scripts/apply-uat-sql.mjs staging/supabase/migrations/20260923120000_pc_chat_uat_live_restore.sql
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import pg from "pg";

const file = process.argv[2];
if (!file) {
  console.error("Usage: node scripts/apply-uat-sql.mjs <migration.sql>");
  process.exit(1);
}

const projectRef = process.env.VITE_SUPABASE_PROJECT_ID || process.env.SUPABASE_PROJECT_ID || "pyrlvjeectjikvfksukb";
const password = process.env.SUPABASE_DB_PASSWORD || process.env.POSTGRES_PASSWORD || "";
const databaseUrl =
  process.env.DATABASE_URL ||
  process.env.SUPABASE_DB_URL ||
  (password
    ? `postgresql://postgres.${projectRef}:${encodeURIComponent(password)}@aws-0-ap-south-1.pooler.supabase.com:6543/postgres`
    : "");
const accessToken = process.env.SUPABASE_ACCESS_TOKEN || "";
const sql = readFileSync(resolve(file), "utf8");

async function applyViaPg(url) {
  const client = new pg.Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
  await client.connect();
  try {
    await client.query(sql);
  } finally {
    await client.end();
  }
}

async function applyViaManagementApi(token) {
  const response = await fetch(`https://api.supabase.com/v1/projects/${projectRef}/database/query`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ query: sql }),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`Management API ${response.status}: ${text.slice(0, 500)}`);
  }
}

if (accessToken) {
  await applyViaManagementApi(accessToken);
  console.log(`Applied via Management API: ${file}`);
} else if (databaseUrl) {
  await applyViaPg(databaseUrl);
  console.log(`Applied via Postgres: ${file}`);
} else {
  console.error("Set DATABASE_URL, SUPABASE_DB_PASSWORD, or SUPABASE_ACCESS_TOKEN to apply SQL to UAT.");
  process.exit(2);
}
