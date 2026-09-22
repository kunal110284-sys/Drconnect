-- Restore post-consultation chat on UAT after 20260912103133 revert.
-- Enables authenticated patient/provider members (not only *@example.invalid pilot),
-- restores real pc_chat_inbox, and adds counterpart_id open for demo pairs.

CREATE SCHEMA IF NOT EXISTS private;

CREATE TABLE IF NOT EXISTS public.post_consultation_chat_policies (
  version text PRIMARY KEY,
  test_only boolean NOT NULL CHECK (test_only),
  duration_seconds integer NOT NULL CHECK (duration_seconds > 0),
  patient_message_limit integer NOT NULL CHECK (patient_message_limit > 0),
  starts_on text NOT NULL,
  scope text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.post_consultation_chat_policies (version, test_only, duration_seconds, patient_message_limit, starts_on, scope)
VALUES ('synthetic-home-followup-v1', true, 86400, 25, 'verified_home_visit_completion', 'episode')
ON CONFLICT (version) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.post_consultation_chat_pilot_participants (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.chat_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES auth.users(id),
  provider_id uuid NOT NULL REFERENCES auth.users(id),
  scope_key text NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (patient_id <> provider_id),
  UNIQUE (patient_id, provider_id, scope_key)
);

DO $$ BEGIN
  ALTER TABLE public.chat_conversations DROP CONSTRAINT IF EXISTS chat_conversations_scope_key_check;
  ALTER TABLE public.chat_conversations
    ADD CONSTRAINT chat_conversations_scope_key_check
    CHECK (scope_key IN ('home_visit:direct', 'uat:direct'));
EXCEPTION WHEN others THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS chat_conversations_provider_idx ON public.chat_conversations(provider_id);

CREATE TABLE IF NOT EXISTS public.chat_consultation_episodes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id),
  source_kind text NOT NULL,
  source_id uuid NOT NULL,
  consultation_label text NOT NULL,
  completed_at timestamptz NOT NULL,
  policy_version text NOT NULL REFERENCES public.post_consultation_chat_policies(version),
  policy_snapshot jsonb NOT NULL,
  patient_send_until timestamptz NOT NULL,
  patient_message_limit integer NOT NULL CHECK (patient_message_limit > 0),
  patient_messages_used integer NOT NULL DEFAULT 0
    CHECK (patient_messages_used >= 0 AND patient_messages_used <= patient_message_limit),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_kind, source_id),
  UNIQUE (id, conversation_id)
);

DO $$ BEGIN
  ALTER TABLE public.chat_consultation_episodes DROP CONSTRAINT IF EXISTS chat_consultation_episodes_source_kind_check;
  ALTER TABLE public.chat_consultation_episodes
    ADD CONSTRAINT chat_consultation_episodes_source_kind_check
    CHECK (source_kind IN ('doctor_appointment', 'member_pair'));
EXCEPTION WHEN others THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS chat_episodes_conversation_idx
  ON public.chat_consultation_episodes(conversation_id, completed_at DESC, id);

ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS conversation_id uuid REFERENCES public.chat_conversations(id);
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS episode_id uuid;
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS sender_role text;
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS idempotency_key text;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'chat_messages' AND column_name = 'sequence_id'
  ) THEN
    ALTER TABLE public.chat_messages ADD COLUMN sequence_id bigint GENERATED ALWAYS AS IDENTITY;
  END IF;
END $$;

DO $$ BEGIN
  ALTER TABLE public.chat_messages DROP CONSTRAINT IF EXISTS chat_message_episode_fk;
  ALTER TABLE public.chat_messages
    ADD CONSTRAINT chat_message_episode_fk
    FOREIGN KEY (episode_id, conversation_id)
    REFERENCES public.chat_consultation_episodes(id, conversation_id);
EXCEPTION WHEN others THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE public.chat_messages DROP CONSTRAINT IF EXISTS chat_message_canonical_shape;
  ALTER TABLE public.chat_messages ADD CONSTRAINT chat_message_canonical_shape CHECK (
    (conversation_id IS NULL AND episode_id IS NULL AND sender_role IS NULL AND idempotency_key IS NULL)
    OR (conversation_id IS NOT NULL AND episode_id IS NOT NULL AND sender_role IS NOT NULL
        AND idempotency_key IS NOT NULL AND recipient_id IS NOT NULL)
  );
EXCEPTION WHEN others THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE public.chat_messages DROP CONSTRAINT IF EXISTS chat_message_actor_idempotency;
  ALTER TABLE public.chat_messages ADD CONSTRAINT chat_message_actor_idempotency UNIQUE (sender_id, idempotency_key);
EXCEPTION WHEN others THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE public.chat_messages DROP CONSTRAINT IF EXISTS chat_messages_sender_role_check;
  ALTER TABLE public.chat_messages
    ADD CONSTRAINT chat_messages_sender_role_check
    CHECK (sender_role IS NULL OR sender_role IN ('patient', 'doctor'));
EXCEPTION WHEN others THEN NULL;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS chat_messages_sequence_idx ON public.chat_messages(sequence_id);
CREATE INDEX IF NOT EXISTS chat_messages_conversation_sequence_idx
  ON public.chat_messages(conversation_id, sequence_id DESC) WHERE conversation_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.chat_member_receipts (
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id),
  member_id uuid NOT NULL REFERENCES auth.users(id),
  last_read_sequence bigint NOT NULL DEFAULT 0 CHECK (last_read_sequence >= 0),
  acknowledged_at timestamptz,
  PRIMARY KEY (conversation_id, member_id)
);

CREATE TABLE IF NOT EXISTS public.chat_message_debits (
  message_id uuid PRIMARY KEY REFERENCES public.chat_messages(id),
  episode_id uuid NOT NULL REFERENCES public.chat_consultation_episodes(id),
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  units integer NOT NULL CHECK (units = 1),
  policy_version text NOT NULL REFERENCES public.post_consultation_chat_policies(version),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.chat_prescription_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id),
  episode_id uuid NOT NULL,
  requested_by uuid NOT NULL REFERENCES auth.users(id),
  idempotency_key text NOT NULL,
  status text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested', 'reviewing', 'declined')),
  requested_at timestamptz NOT NULL DEFAULT now(),
  reviewed_by uuid REFERENCES auth.users(id),
  reviewed_at timestamptz,
  decline_reason text,
  FOREIGN KEY (episode_id, conversation_id) REFERENCES public.chat_consultation_episodes(id, conversation_id),
  UNIQUE (requested_by, idempotency_key)
);

CREATE TABLE IF NOT EXISTS public.chat_prescription_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES public.chat_prescription_requests(id),
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  from_status text,
  to_status text NOT NULL CHECK (to_status IN ('requested', 'reviewing', 'declined')),
  reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (request_id, to_status)
);

CREATE TABLE IF NOT EXISTS public.chat_notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id),
  episode_id uuid NOT NULL REFERENCES public.chat_consultation_episodes(id),
  message_id uuid REFERENCES public.chat_messages(id),
  prescription_request_id uuid REFERENCES public.chat_prescription_requests(id),
  recipient_id uuid NOT NULL REFERENCES auth.users(id),
  event_kind text NOT NULL CHECK (event_kind IN (
    'message_saved', 'prescription_requested', 'prescription_reviewing', 'prescription_declined'
  )),
  dedupe_key text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'disabled' CHECK (status = 'disabled'),
  created_at timestamptz NOT NULL DEFAULT now()
);

DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY[
    'post_consultation_chat_policies',
    'post_consultation_chat_pilot_participants',
    'chat_conversations',
    'chat_consultation_episodes',
    'chat_member_receipts',
    'chat_message_debits',
    'chat_prescription_requests',
    'chat_prescription_events',
    'chat_notification_outbox'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION private.pc_chat_immutable() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_TABLE_NAME = 'post_consultation_chat_policies' THEN
    RAISE EXCEPTION 'Chat policy versions are immutable; add a new version';
  END IF;
  IF TG_TABLE_NAME = 'chat_conversations' THEN
    IF (NEW.id, NEW.patient_id, NEW.provider_id, NEW.scope_key, NEW.created_at)
      IS DISTINCT FROM (OLD.id, OLD.patient_id, OLD.provider_id, OLD.scope_key, OLD.created_at) THEN
      RAISE EXCEPTION 'Conversation participants and scope are immutable';
    END IF;
  END IF;
  IF TG_TABLE_NAME = 'chat_consultation_episodes' THEN
    IF (to_jsonb(NEW) - 'patient_messages_used') IS DISTINCT FROM (to_jsonb(OLD) - 'patient_messages_used') THEN
      RAISE EXCEPTION 'Consultation episode and policy snapshot are immutable';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS chat_policy_immutable ON public.post_consultation_chat_policies;
CREATE TRIGGER chat_policy_immutable BEFORE UPDATE OR DELETE ON public.post_consultation_chat_policies
  FOR EACH ROW EXECUTE FUNCTION private.pc_chat_immutable();
DROP TRIGGER IF EXISTS chat_conversation_immutable ON public.chat_conversations;
CREATE TRIGGER chat_conversation_immutable BEFORE UPDATE ON public.chat_conversations
  FOR EACH ROW EXECUTE FUNCTION private.pc_chat_immutable();
DROP TRIGGER IF EXISTS chat_episode_immutable ON public.chat_consultation_episodes;
CREATE TRIGGER chat_episode_immutable BEFORE UPDATE ON public.chat_consultation_episodes
  FOR EACH ROW EXECUTE FUNCTION private.pc_chat_immutable();

-- UAT: enabled when allowlisted OR ordinary authenticated patient/provider (not revoked).
CREATE OR REPLACE FUNCTION private.pc_chat_enabled(p_uid uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p_uid IS NOT NULL AND (
    EXISTS (
      SELECT 1 FROM public.post_consultation_chat_pilot_participants p
      WHERE p.user_id = p_uid AND p.revoked_at IS NULL
    )
    OR EXISTS (
      SELECT 1 FROM public.user_roles r
      WHERE r.user_id = p_uid AND r.role IN ('patient', 'provider')
    )
  );
$$;

-- UAT: approved provider is enough (demo doctors may lack care_physician_profiles).
CREATE OR REPLACE FUNCTION private.pc_chat_doctor(p_uid uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles WHERE user_id = p_uid AND role = 'provider'
  ) AND EXISTS (
    SELECT 1 FROM public.account_role_requests
    WHERE user_id = p_uid AND status = 'approved' AND requested_role = 'provider'
  );
$$;

CREATE OR REPLACE FUNCTION private.pc_chat_member(p_conversation uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.chat_conversations c
    WHERE c.id = p_conversation AND c.revoked_at IS NULL
      AND auth.uid() IN (c.patient_id, c.provider_id)
      AND private.pc_chat_enabled(c.patient_id)
      AND private.pc_chat_enabled(c.provider_id)
      AND private.pc_chat_doctor(c.provider_id)
  );
$$;

CREATE OR REPLACE FUNCTION private.pc_chat_require(p_conversation uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in to open follow-up chat' USING ERRCODE = '42501';
  END IF;
  IF NOT private.pc_chat_member(p_conversation) THEN
    RAISE EXCEPTION 'Chat access is unavailable or revoked' USING ERRCODE = '42501';
  END IF;
  RETURN auth.uid();
END $$;

CREATE OR REPLACE FUNCTION private.pc_surgery_member(p_thread text, p_sender uuid, p_recipient uuid, p_write boolean)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.surgery_booking_roles r
    JOIN public.surgery_bookings b ON b.id = r.booking_id
    WHERE p_thread = 'surgery:' || r.id::text AND r.assigned_to IS NOT NULL
      AND auth.uid() IN (b.facility_id, r.assigned_to)
      AND ((p_sender = b.facility_id AND p_recipient = r.assigned_to)
        OR (p_sender = r.assigned_to AND p_recipient = b.facility_id))
      AND (NOT p_write OR (r.status = 'accepted' AND b.status <> 'cancelled'
        AND (r.chat_expires_at IS NULL OR r.chat_expires_at > now())))
  );
$$;

DROP POLICY IF EXISTS "authorised canonical and historical messages" ON public.chat_messages;
DROP POLICY IF EXISTS "verified surgical role messages only" ON public.chat_messages;
DROP POLICY IF EXISTS "participants can read" ON public.chat_messages;
DROP POLICY IF EXISTS "sender can insert" ON public.chat_messages;

CREATE POLICY "authorised canonical and historical messages" ON public.chat_messages
FOR SELECT TO authenticated USING (
  (conversation_id IS NOT NULL AND private.pc_chat_member(conversation_id))
  OR (conversation_id IS NULL AND CASE
    WHEN thread_key LIKE 'surgery:%' THEN private.pc_surgery_member(thread_key, sender_id, recipient_id, false)
    ELSE (auth.uid() = sender_id OR auth.uid() = recipient_id)
  END)
);

CREATE POLICY "verified surgical role messages only" ON public.chat_messages
FOR INSERT TO authenticated WITH CHECK (
  conversation_id IS NULL AND episode_id IS NULL AND sender_role IS NULL AND idempotency_key IS NULL
  AND auth.uid() = sender_id AND length(trim(body)) BETWEEN 1 AND 4000
  AND private.pc_surgery_member(thread_key, sender_id, recipient_id, true)
);

REVOKE ALL ON public.chat_messages FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.chat_messages TO authenticated;
GRANT ALL ON public.chat_messages TO service_role;

CREATE OR REPLACE FUNCTION private.pc_chat_summary(p_conversation uuid, p_episode uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  u uuid := private.pc_chat_require(p_conversation);
  c public.chat_conversations;
  e public.chat_consultation_episodes;
  other_user uuid;
  member text;
  receipt bigint;
  can_send boolean;
  latest public.chat_messages;
BEGIN
  SELECT * INTO c FROM public.chat_conversations WHERE id = p_conversation;
  SELECT * INTO e FROM public.chat_consultation_episodes
  WHERE conversation_id = c.id AND (p_episode IS NULL OR id = p_episode)
  ORDER BY completed_at DESC, id DESC LIMIT 1;
  IF e.id IS NULL THEN RAISE EXCEPTION 'Authorised consultation episode required'; END IF;
  member := CASE WHEN u = c.provider_id THEN 'doctor' ELSE 'patient' END;
  other_user := CASE WHEN member = 'doctor' THEN c.patient_id ELSE c.provider_id END;
  SELECT COALESCE(last_read_sequence, 0) INTO receipt
  FROM public.chat_member_receipts WHERE conversation_id = c.id AND member_id = u;
  SELECT * INTO latest FROM public.chat_messages WHERE conversation_id = c.id ORDER BY sequence_id DESC LIMIT 1;
  can_send := member = 'doctor' OR (now() < e.patient_send_until AND e.patient_messages_used < e.patient_message_limit);
  RETURN jsonb_build_object(
    'conversation_id', c.id,
    'episode_id', e.id,
    'source_kind', e.source_kind,
    'source_id', e.source_id,
    'actor_id', u,
    'member_role', member,
    'other_id', other_user,
    'other_name', (
      SELECT COALESCE(NULLIF(full_name, ''), CASE WHEN member = 'doctor' THEN 'Patient' ELSE 'Doctor' END)
      FROM public.profiles WHERE id = other_user
    ),
    'other_role', CASE WHEN member = 'doctor' THEN 'patient' ELSE 'doctor' END,
    'consultation_label', e.consultation_label,
    'completed_at', e.completed_at,
    'patient_messages_remaining', e.patient_message_limit - e.patient_messages_used,
    'patient_messages_limit', e.patient_message_limit,
    'patient_send_until', e.patient_send_until,
    'can_send', can_send,
    'send_disabled_reason', CASE
      WHEN can_send THEN NULL
      WHEN now() >= e.patient_send_until THEN 'The follow-up message allowance has expired'
      ELSE 'The patient message allowance is exhausted'
    END,
    'last_body', latest.body,
    'last_at', latest.created_at,
    'last_read_sequence', COALESCE(receipt, 0),
    'unread_count', (
      SELECT count(*) FROM public.chat_messages
      WHERE conversation_id = c.id AND recipient_id = u AND sequence_id > COALESCE(receipt, 0)
    ),
    'policy_version', e.policy_version,
    'test_only', true,
    'episodes', (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'episode_id', id,
          'source_kind', source_kind,
          'source_id', source_id,
          'consultation_label', consultation_label,
          'completed_at', completed_at
        ) ORDER BY completed_at DESC, id DESC
      ), '[]'::jsonb)
      FROM public.chat_consultation_episodes WHERE conversation_id = c.id
    ),
    'prescription_requests', (
      SELECT COALESCE(jsonb_agg(to_jsonb(r) - 'idempotency_key' ORDER BY requested_at DESC), '[]'::jsonb)
      FROM public.chat_prescription_requests r WHERE conversation_id = c.id
    )
  );
END $$;

CREATE OR REPLACE FUNCTION private.pc_chat_context() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'enabled', private.pc_chat_enabled(auth.uid()),
    'test_only', true,
    'policy_version', 'synthetic-home-followup-v1',
    'unavailable_reason', CASE
      WHEN private.pc_chat_enabled(auth.uid()) THEN NULL
      ELSE 'Sign in as a patient or approved provider to use follow-up chat'
    END,
    'attachments_enabled', false,
    'calls_enabled', false,
    'payments_enabled', false,
    'prescription_issuance_enabled', false,
    'notifications_enabled', false
  );
$$;

CREATE OR REPLACE FUNCTION private.pc_chat_ensure_pair(p_patient uuid, p_provider uuid, p_label text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  u uuid := auth.uid();
  cid uuid;
  eid uuid;
  sid uuid;
  p public.post_consultation_chat_policies;
BEGIN
  IF u IS NULL OR u NOT IN (p_patient, p_provider) THEN
    RAISE EXCEPTION 'Authorised chat participants required' USING ERRCODE = '42501';
  END IF;
  IF NOT private.pc_chat_enabled(p_patient) OR NOT private.pc_chat_enabled(p_provider) OR NOT private.pc_chat_doctor(p_provider) THEN
    RAISE EXCEPTION 'Both participants must be eligible for follow-up chat' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.chat_conversations (patient_id, provider_id, scope_key)
  VALUES (p_patient, p_provider, 'uat:direct')
  ON CONFLICT (patient_id, provider_id, scope_key) DO NOTHING;
  SELECT id INTO cid FROM public.chat_conversations
  WHERE patient_id = p_patient AND provider_id = p_provider AND scope_key = 'uat:direct' FOR UPDATE;
  PERFORM private.pc_chat_require(cid);
  SELECT * INTO p FROM public.post_consultation_chat_policies WHERE version = 'synthetic-home-followup-v1';
  sid := (
    substr(md5(p_patient::text || ':' || p_provider::text || ':uat:direct'), 1, 8) || '-' ||
    substr(md5(p_patient::text || ':' || p_provider::text || ':uat:direct'), 9, 4) || '-4' ||
    substr(md5(p_patient::text || ':' || p_provider::text || ':uat:direct'), 14, 3) || '-a' ||
    substr(md5(p_patient::text || ':' || p_provider::text || ':uat:direct'), 18, 3) || '-' ||
    substr(md5(p_patient::text || ':' || p_provider::text || ':uat:direct'), 21, 12)
  )::uuid;
  INSERT INTO public.chat_consultation_episodes (
    conversation_id, source_kind, source_id, consultation_label, completed_at,
    policy_version, policy_snapshot, patient_send_until, patient_message_limit
  ) VALUES (
    cid, 'member_pair', sid, COALESCE(NULLIF(p_label, ''), 'Follow-up consultation'), now(),
    p.version, to_jsonb(p), now() + make_interval(secs => p.duration_seconds), p.patient_message_limit
  ) ON CONFLICT (source_kind, source_id) DO NOTHING;
  SELECT id INTO eid FROM public.chat_consultation_episodes
  WHERE source_kind = 'member_pair' AND source_id = sid AND conversation_id = cid;
  IF eid IS NULL THEN
    RAISE EXCEPTION 'Consultation identity changed; reviewed reconciliation required';
  END IF;
  INSERT INTO public.chat_member_receipts (conversation_id, member_id)
  VALUES (cid, p_patient), (cid, p_provider) ON CONFLICT DO NOTHING;
  RETURN private.pc_chat_summary(cid, eid);
END $$;

CREATE OR REPLACE FUNCTION private.pc_chat_open(p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  u uuid := auth.uid();
  cid uuid;
  eid uuid;
  sid uuid;
  counterpart uuid;
  patient_id uuid;
  provider_id uuid;
  a public.doctor_appointments;
  p public.post_consultation_chat_policies;
BEGIN
  IF u IS NULL OR NOT private.pc_chat_enabled(u) THEN
    RAISE EXCEPTION 'Follow-up chat is unavailable for this account' USING ERRCODE = '42501';
  END IF;

  IF NULLIF(p_input ->> 'conversation_id', '') IS NOT NULL THEN
    RETURN private.pc_chat_summary((p_input ->> 'conversation_id')::uuid, NULLIF(p_input ->> 'episode_id', '')::uuid);
  END IF;

  IF NULLIF(p_input ->> 'counterpart_id', '') IS NOT NULL THEN
    counterpart := (p_input ->> 'counterpart_id')::uuid;
    IF EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = u AND role = 'provider')
       AND private.pc_chat_doctor(u) THEN
      patient_id := counterpart;
      provider_id := u;
    ELSE
      patient_id := u;
      provider_id := counterpart;
    END IF;
    RETURN private.pc_chat_ensure_pair(
      patient_id,
      provider_id,
      COALESCE(NULLIF(p_input ->> 'consultation_label', ''), 'Follow-up consultation')
    );
  END IF;

  IF COALESCE(p_input ->> 'source_kind', '') NOT IN ('doctor_appointment', 'home_visit') THEN
    RAISE EXCEPTION 'Open chat from an authorised consultation or counterpart';
  END IF;

  sid := (p_input ->> 'source_id')::uuid;
  SELECT * INTO a FROM public.doctor_appointments WHERE id = sid;
  IF NOT FOUND OR (u <> a.patient_id AND u IS DISTINCT FROM a.provider_id) THEN
    RAISE EXCEPTION 'Authorised completed consultation required' USING ERRCODE = '42501';
  END IF;
  IF a.status NOT IN ('completed', 'confirmed') THEN
    RAISE EXCEPTION 'Authorised completed consultation required' USING ERRCODE = '42501';
  END IF;
  IF NOT private.pc_chat_enabled(a.patient_id) OR NOT private.pc_chat_enabled(a.provider_id)
     OR NOT private.pc_chat_doctor(a.provider_id) THEN
    RAISE EXCEPTION 'Both participants must be eligible for follow-up chat' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.chat_conversations (patient_id, provider_id, scope_key)
  VALUES (a.patient_id, a.provider_id, 'home_visit:direct')
  ON CONFLICT (patient_id, provider_id, scope_key) DO NOTHING;
  SELECT id INTO cid FROM public.chat_conversations
  WHERE patient_id = a.patient_id AND provider_id = a.provider_id AND scope_key = 'home_visit:direct' FOR UPDATE;
  PERFORM private.pc_chat_require(cid);
  SELECT * INTO p FROM public.post_consultation_chat_policies WHERE version = 'synthetic-home-followup-v1';
  INSERT INTO public.chat_consultation_episodes (
    conversation_id, source_kind, source_id, consultation_label, completed_at,
    policy_version, policy_snapshot, patient_send_until, patient_message_limit
  ) VALUES (
    cid, 'doctor_appointment', a.id, COALESCE(a.service, 'Consultation'),
    COALESCE(a.completed_at, a.updated_at, now()), p.version, to_jsonb(p),
    COALESCE(a.completed_at, a.updated_at, now()) + make_interval(secs => p.duration_seconds),
    p.patient_message_limit
  ) ON CONFLICT (source_kind, source_id) DO NOTHING;
  SELECT id INTO eid FROM public.chat_consultation_episodes
  WHERE source_kind = 'doctor_appointment' AND source_id = a.id AND conversation_id = cid;
  IF eid IS NULL THEN
    RAISE EXCEPTION 'Consultation identity changed; reviewed reconciliation required';
  END IF;
  INSERT INTO public.chat_member_receipts (conversation_id, member_id)
  VALUES (cid, a.patient_id), (cid, a.provider_id) ON CONFLICT DO NOTHING;
  RETURN private.pc_chat_summary(cid, eid);
END $$;

CREATE OR REPLACE FUNCTION private.pc_chat_inbox() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in to read follow-up chats' USING ERRCODE = '42501';
  END IF;
  IF NOT private.pc_chat_enabled(auth.uid()) THEN
    RETURN '[]'::jsonb;
  END IF;
  SELECT COALESCE(
    jsonb_agg(row_data ORDER BY COALESCE(row_data ->> 'last_at', row_data ->> 'completed_at') DESC, row_data ->> 'conversation_id'),
    '[]'::jsonb
  ) INTO result
  FROM (
    SELECT private.pc_chat_summary(id) AS row_data
    FROM public.chat_conversations
    WHERE private.pc_chat_member(id)
  ) q;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION private.pc_chat_history(p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  cid uuid := (p_input ->> 'conversation_id')::uuid;
  n integer := LEAST(100, GREATEST(1, COALESCE((p_input ->> 'limit')::integer, 50)));
  before_id bigint := NULLIF(p_input ->> 'before_sequence', '')::bigint;
  after_id bigint := NULLIF(p_input ->> 'after_sequence', '')::bigint;
  rows jsonb;
  next_id bigint;
BEGIN
  PERFORM private.pc_chat_require(cid);
  SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY sequence_id), '[]'::jsonb), min(sequence_id)
  INTO rows, next_id
  FROM (
    SELECT id, conversation_id, episode_id, sender_id, sender_role, body, created_at, sequence_id, idempotency_key
    FROM public.chat_messages
    WHERE conversation_id = cid
      AND (before_id IS NULL OR sequence_id < before_id)
      AND (after_id IS NULL OR sequence_id > after_id)
    ORDER BY CASE WHEN after_id IS NOT NULL THEN sequence_id END ASC, sequence_id DESC
    LIMIT n
  ) q;
  RETURN jsonb_build_object(
    'messages', rows,
    'next_before_sequence', CASE
      WHEN EXISTS (SELECT 1 FROM public.chat_messages WHERE conversation_id = cid AND sequence_id < next_id)
      THEN next_id ELSE NULL
    END
  );
END $$;

CREATE OR REPLACE FUNCTION private.pc_chat_send(p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  cid uuid := (p_input ->> 'conversation_id')::uuid;
  eid uuid := (p_input ->> 'episode_id')::uuid;
  u uuid := private.pc_chat_require(cid);
  c public.chat_conversations;
  e public.chat_consultation_episodes;
  m public.chat_messages;
  message_body text := trim(COALESCE(p_input ->> 'body', ''));
  key text := p_input ->> 'idempotency_key';
  member text;
  recipient uuid;
BEGIN
  IF EXISTS (
    SELECT 1 FROM jsonb_object_keys(p_input) k
    WHERE k NOT IN ('conversation_id', 'episode_id', 'body', 'idempotency_key')
  ) THEN
    RAISE EXCEPTION 'Unsupported message fields; only text messages are enabled';
  END IF;
  IF length(message_body) NOT BETWEEN 1 AND 4000 OR octet_length(message_body) > 16000 THEN
    RAISE EXCEPTION 'Message must contain 1 to 4000 characters';
  END IF;
  IF key IS NULL OR length(key) NOT BETWEEN 8 AND 128 THEN
    RAISE EXCEPTION 'A stable idempotency key is required';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(u::text || ':' || key, 17));
  SELECT * INTO c FROM public.chat_conversations WHERE id = cid FOR UPDATE;
  PERFORM private.pc_chat_require(cid);
  SELECT * INTO m FROM public.chat_messages WHERE sender_id = u AND idempotency_key = key;
  IF FOUND THEN
    IF m.conversation_id IS DISTINCT FROM cid OR m.episode_id IS DISTINCT FROM eid OR m.body IS DISTINCT FROM message_body THEN
      RAISE EXCEPTION 'Idempotency key was already used for a different message';
    END IF;
    RETURN to_jsonb(m) - 'thread_key' - 'recipient_id';
  END IF;
  SELECT * INTO e FROM public.chat_consultation_episodes WHERE id = eid AND conversation_id = cid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Authorised consultation episode required'; END IF;
  member := CASE WHEN u = c.provider_id THEN 'doctor' ELSE 'patient' END;
  recipient := CASE WHEN member = 'doctor' THEN c.patient_id ELSE c.provider_id END;
  IF member = 'patient' THEN
    IF now() >= e.patient_send_until THEN RAISE EXCEPTION 'The follow-up message allowance has expired'; END IF;
    IF e.patient_messages_used >= e.patient_message_limit THEN
      RAISE EXCEPTION 'The patient message allowance is exhausted';
    END IF;
  END IF;
  INSERT INTO public.chat_messages (
    thread_key, sender_id, recipient_id, body, conversation_id, episode_id, sender_role, idempotency_key
  ) VALUES (
    'consultation:' || cid::text, u, recipient, message_body, cid, eid, member, key
  ) RETURNING * INTO m;
  IF member = 'patient' THEN
    UPDATE public.chat_consultation_episodes SET patient_messages_used = patient_messages_used + 1 WHERE id = eid;
    INSERT INTO public.chat_message_debits (message_id, episode_id, actor_id, units, policy_version)
    VALUES (m.id, eid, u, 1, e.policy_version);
  END IF;
  INSERT INTO public.chat_notification_outbox (
    conversation_id, episode_id, message_id, recipient_id, event_kind, dedupe_key
  ) VALUES (cid, eid, m.id, recipient, 'message_saved', 'message:' || m.id::text);
  RETURN to_jsonb(m) - 'thread_key' - 'recipient_id';
END $$;

CREATE OR REPLACE FUNCTION private.pc_chat_ack_read(p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  cid uuid := (p_input ->> 'conversation_id')::uuid;
  u uuid := private.pc_chat_require(cid);
  seq bigint := (p_input ->> 'through_sequence')::bigint;
  saved bigint;
BEGIN
  IF seq IS NULL OR seq < 0 OR (
    seq <> 0 AND NOT EXISTS (SELECT 1 FROM public.chat_messages WHERE conversation_id = cid AND sequence_id = seq)
  ) THEN
    RAISE EXCEPTION 'A displayed message from this conversation is required';
  END IF;
  INSERT INTO public.chat_member_receipts (conversation_id, member_id, last_read_sequence, acknowledged_at)
  VALUES (cid, u, seq, now())
  ON CONFLICT (conversation_id, member_id) DO UPDATE
  SET last_read_sequence = GREATEST(public.chat_member_receipts.last_read_sequence, excluded.last_read_sequence),
      acknowledged_at = now()
  RETURNING last_read_sequence INTO saved;
  RETURN jsonb_build_object('last_read_sequence', saved);
END $$;

CREATE OR REPLACE FUNCTION private.pc_chat_prescription(p_input jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  cid uuid := (p_input ->> 'conversation_id')::uuid;
  eid uuid := (p_input ->> 'episode_id')::uuid;
  u uuid := private.pc_chat_require(cid);
  action text := p_input ->> 'action';
  c public.chat_conversations;
  r public.chat_prescription_requests;
  key text := p_input ->> 'idempotency_key';
  recipient uuid;
  event text;
  previous_status text;
BEGIN
  IF action NOT IN ('request', 'review', 'decline') OR action IS NULL THEN
    RAISE EXCEPTION 'Signed prescription issuance is not integrated; supported actions are request, review and decline';
  END IF;
  IF action = 'request' THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(u::text || ':prescription:' || COALESCE(key, ''), 17));
  END IF;
  SELECT * INTO c FROM public.chat_conversations WHERE id = cid FOR UPDATE;
  PERFORM private.pc_chat_require(cid);
  IF NOT EXISTS (SELECT 1 FROM public.chat_consultation_episodes WHERE id = eid AND conversation_id = cid) THEN
    RAISE EXCEPTION 'Authorised consultation episode required';
  END IF;
  IF action = 'request' THEN
    IF u <> c.patient_id THEN RAISE EXCEPTION 'Only the patient can request a prescription'; END IF;
    IF key IS NULL OR length(key) NOT BETWEEN 8 AND 128 THEN
      RAISE EXCEPTION 'A stable idempotency key is required';
    END IF;
    SELECT * INTO r FROM public.chat_prescription_requests WHERE requested_by = u AND idempotency_key = key;
    IF FOUND THEN RETURN to_jsonb(r) - 'idempotency_key'; END IF;
    INSERT INTO public.chat_prescription_requests (conversation_id, episode_id, requested_by, idempotency_key)
    VALUES (cid, eid, u, key) RETURNING * INTO r;
    event := 'prescription_requested';
    recipient := c.provider_id;
  ELSE
    IF u <> c.provider_id THEN RAISE EXCEPTION 'Only the doctor can review a prescription request'; END IF;
    SELECT * INTO r FROM public.chat_prescription_requests WHERE id = (p_input ->> 'request_id')::uuid FOR UPDATE;
    IF NOT FOUND OR r.conversation_id <> cid THEN RAISE EXCEPTION 'Prescription request not found'; END IF;
    previous_status := r.status;
    IF action = 'review' THEN
      UPDATE public.chat_prescription_requests
      SET status = 'reviewing', reviewed_by = u, reviewed_at = now()
      WHERE id = r.id RETURNING * INTO r;
      event := 'prescription_reviewing';
    ELSE
      UPDATE public.chat_prescription_requests
      SET status = 'declined', reviewed_by = u, reviewed_at = now(),
          decline_reason = NULLIF(trim(COALESCE(p_input ->> 'decline_reason', '')), '')
      WHERE id = r.id RETURNING * INTO r;
      event := 'prescription_declined';
    END IF;
    recipient := r.requested_by;
    INSERT INTO public.chat_prescription_events (request_id, actor_id, from_status, to_status, reason)
    VALUES (r.id, u, previous_status, r.status, r.decline_reason);
  END IF;
  INSERT INTO public.chat_notification_outbox (
    conversation_id, episode_id, prescription_request_id, recipient_id, event_kind, dedupe_key
  ) VALUES (cid, eid, r.id, recipient, event, event || ':' || r.id::text)
  ON CONFLICT (dedupe_key) DO NOTHING;
  RETURN to_jsonb(r) - 'idempotency_key';
END $$;

CREATE OR REPLACE FUNCTION public.pc_chat_context() RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.pc_chat_context() $$;
CREATE OR REPLACE FUNCTION public.pc_chat_inbox() RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.pc_chat_inbox() $$;
CREATE OR REPLACE FUNCTION public.pc_chat_open(p_input jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.pc_chat_open(p_input) $$;
CREATE OR REPLACE FUNCTION public.pc_chat_history(p_input jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.pc_chat_history(p_input) $$;
CREATE OR REPLACE FUNCTION public.pc_chat_send(p_input jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.pc_chat_send(p_input) $$;
CREATE OR REPLACE FUNCTION public.pc_chat_ack_read(p_input jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.pc_chat_ack_read(p_input) $$;
CREATE OR REPLACE FUNCTION public.pc_chat_prescription(p_input jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$ SELECT private.pc_chat_prescription(p_input) $$;

DO $$ DECLARE f record; BEGIN
  FOR f IN
    SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('private', 'public')
      AND (p.proname LIKE 'pc_chat_%' OR p.proname = 'pc_surgery_member')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %I.%I(%s) FROM PUBLIC, anon, authenticated', f.nspname, f.proname, f.args);
    IF f.proname <> 'pc_chat_immutable' THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %I.%I(%s) TO authenticated, service_role', f.nspname, f.proname, f.args);
    END IF;
  END LOOP;
END $$;

GRANT USAGE ON SCHEMA private TO authenticated;

DO $$ BEGIN
  GRANT USAGE, SELECT ON SEQUENCE public.chat_messages_sequence_id_seq TO authenticated, service_role;
EXCEPTION WHEN undefined_table THEN
  RAISE NOTICE 'chat_messages_sequence_id_seq not present yet';
WHEN undefined_object THEN
  RAISE NOTICE 'chat_messages_sequence_id_seq grant skipped';
END $$;

-- Seed known demo accounts into the allowlist (idempotent).
INSERT INTO public.post_consultation_chat_pilot_participants (user_id)
VALUES
  ('098ad3c8-3a77-4702-8494-ec007855e219'),
  ('5f27622d-117e-4772-ad6d-f45ce90898fe'),
  ('26fe34e0-1757-400b-9ffd-5325aa1b32b6'),
  ('490a20be-87cd-4340-b462-3429472e9d02')
ON CONFLICT (user_id) DO UPDATE SET revoked_at = NULL;

-- Ensure demo patient/doctor conversation exists for live smoke.
DO $$
DECLARE
  patient uuid := '098ad3c8-3a77-4702-8494-ec007855e219';
  provider uuid := '5f27622d-117e-4772-ad6d-f45ce90898fe';
  cid uuid;
  eid uuid;
  sid uuid;
  pol public.post_consultation_chat_policies;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = patient)
     OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = provider) THEN
    RETURN;
  END IF;
  INSERT INTO public.chat_conversations (patient_id, provider_id, scope_key)
  VALUES (patient, provider, 'uat:direct')
  ON CONFLICT (patient_id, provider_id, scope_key) DO NOTHING;
  SELECT id INTO cid FROM public.chat_conversations
  WHERE patient_id = patient AND provider_id = provider AND scope_key = 'uat:direct';
  SELECT * INTO pol FROM public.post_consultation_chat_policies WHERE version = 'synthetic-home-followup-v1';
  sid := (
    substr(md5(patient::text || ':' || provider::text || ':uat:direct'), 1, 8) || '-' ||
    substr(md5(patient::text || ':' || provider::text || ':uat:direct'), 9, 4) || '-4' ||
    substr(md5(patient::text || ':' || provider::text || ':uat:direct'), 14, 3) || '-a' ||
    substr(md5(patient::text || ':' || provider::text || ':uat:direct'), 18, 3) || '-' ||
    substr(md5(patient::text || ':' || provider::text || ':uat:direct'), 21, 12)
  )::uuid;
  INSERT INTO public.chat_consultation_episodes (
    conversation_id, source_kind, source_id, consultation_label, completed_at,
    policy_version, policy_snapshot, patient_send_until, patient_message_limit
  ) VALUES (
    cid, 'member_pair', sid, 'General Physician • Demo follow-up', now(),
    pol.version, to_jsonb(pol), now() + interval '30 days', pol.patient_message_limit
  ) ON CONFLICT (source_kind, source_id) DO NOTHING;
  INSERT INTO public.chat_member_receipts (conversation_id, member_id)
  VALUES (cid, patient), (cid, provider) ON CONFLICT DO NOTHING;
END $$;

-- Realtime: ensure chat_messages is in the supabase_realtime publication.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'chat_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
  END IF;
EXCEPTION WHEN others THEN
  RAISE NOTICE 'Realtime publication update skipped: %', SQLERRM;
END $$;

NOTIFY pgrst, 'reload schema';
