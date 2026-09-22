#!/usr/bin/env node
/**
 * UAT smoke: demo patient + doctor open the same conversation, send, and see history.
 * Requires pc_chat_* restore migration applied.
 *
 *   node --env-file=environments/uat.env scripts/smoke-pc-chat-uat.mjs
 */
import { createClient } from "@supabase/supabase-js";

const url = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL;
const anon = process.env.SUPABASE_PUBLISHABLE_KEY || process.env.VITE_SUPABASE_PUBLISHABLE_KEY;
const special = process.env.MYDOX_DEMO_SPECIAL_PASSWORD || "CareDemo!2026";
const demo = process.env.MYDOX_DEMO_PASSWORD || "demo123456";

if (!url || !anon) {
  console.error("Missing SUPABASE_URL / publishable key");
  process.exit(2);
}

function client() {
  return createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
}

async function login(email) {
  const sb = client();
  let result = await sb.auth.signInWithPassword({ email, password: special });
  if (result.error) result = await sb.auth.signInWithPassword({ email, password: demo });
  if (result.error) throw new Error(`login ${email}: ${result.error.message}`);
  return sb;
}

async function rpc(sb, name, input) {
  const args = input === undefined ? {} : { p_input: input };
  const { data, error } = await sb.rpc(name, args);
  if (error) throw new Error(`${name}: ${error.code || ""} ${error.message}`);
  return data;
}

const patient = await login("patient1@demo.med");
const doctor = await login("medico2@demo.med");

const patientOpen = await rpc(patient, "pc_chat_open", {
  counterpart_id: "5f27622d-117e-4772-ad6d-f45ce90898fe",
  consultation_label: "Smoke follow-up",
});
const doctorOpen = await rpc(doctor, "pc_chat_open", {
  counterpart_id: "098ad3c8-3a77-4702-8494-ec007855e219",
  consultation_label: "Smoke follow-up",
});

if (patientOpen.conversation_id !== doctorOpen.conversation_id) {
  throw new Error(`conversation mismatch ${patientOpen.conversation_id} vs ${doctorOpen.conversation_id}`);
}

const key = `smoke-${Date.now()}-${Math.random().toString(16).slice(2)}`;
const body = `patient smoke ${new Date().toISOString()}`;
const sent = await rpc(patient, "pc_chat_send", {
  conversation_id: patientOpen.conversation_id,
  episode_id: patientOpen.episode_id,
  body,
  idempotency_key: key,
});

const doctorHistory = await rpc(doctor, "pc_chat_history", {
  conversation_id: doctorOpen.conversation_id,
  limit: 20,
});
const seen = (doctorHistory.messages || []).some((m) => m.id === sent.id || m.body === body);
if (!seen) throw new Error("doctor history missing patient message");

const replyKey = `smoke-doc-${Date.now()}`;
const replyBody = `doctor smoke ${new Date().toISOString()}`;
const reply = await rpc(doctor, "pc_chat_send", {
  conversation_id: doctorOpen.conversation_id,
  episode_id: doctorOpen.episode_id,
  body: replyBody,
  idempotency_key: replyKey,
});
const patientHistory = await rpc(patient, "pc_chat_history", {
  conversation_id: patientOpen.conversation_id,
  limit: 20,
});
const seenReply = (patientHistory.messages || []).some((m) => m.id === reply.id || m.body === replyBody);
if (!seenReply) throw new Error("patient history missing doctor reply");

const patientInbox = await rpc(patient, "pc_chat_inbox");
const doctorInbox = await rpc(doctor, "pc_chat_inbox");
if (!Array.isArray(patientInbox) || !patientInbox.some((r) => r.conversation_id === patientOpen.conversation_id)) {
  throw new Error("patient inbox missing conversation");
}
if (!Array.isArray(doctorInbox) || !doctorInbox.some((r) => r.conversation_id === doctorOpen.conversation_id)) {
  throw new Error("doctor inbox missing conversation");
}

console.log(JSON.stringify({
  ok: true,
  conversation_id: patientOpen.conversation_id,
  episode_id: patientOpen.episode_id,
  patient_message_id: sent.id,
  doctor_message_id: reply.id,
}, null, 2));
