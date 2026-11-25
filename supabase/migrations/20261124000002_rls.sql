-- =====================================================================
-- Migración 2: Row Level Security (RLS)
-- =====================================================================
-- Idea clave: con RLS activado y SIN política, nadie ve nada.
-- Cada política abre una puerta específica. Así el principio de
-- "privilegio mínimo" queda en la base de datos, no en el frontend.
-- (La clave anon puede estar en el navegador SOLO porque esto existe.)
-- ---------------------------------------------------------------------

-- ---------- Funciones auxiliares ----------
-- SECURITY DEFINER: se ejecutan con permisos del dueño, así pueden leer
-- admin_roles aunque el usuario no tenga acceso a esa tabla.
-- (select auth.uid()) se escribe entre paréntesis para que Postgres
-- lo evalúe una sola vez por consulta (mejor rendimiento).
create or replace function public.es_admin(p_rol rol_admin default null)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.admin_roles
    where user_id = (select auth.uid()) and (p_rol is null or rol = p_rol)
  );
$$;

-- ¿El usuario aceptó el consentimiento activo (y no lo revocó)? (RF-01)
create or replace function public.tiene_consentimiento()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.consents c
    join public.consent_versions v on v.id = c.consent_version_id
    where c.profile_id = (select auth.uid()) and c.revoked_at is null and v.active
  );
$$;

-- ¿La encuesta es del usuario actual y está editable (borrador + periodo abierto)?
create or replace function public.encuesta_editable(p_survey uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.surveys s
    join public.survey_periods p on p.id = s.period_id
    where s.id = p_survey and s.profile_id = (select auth.uid())
      and s.status = 'borrador' and p.status = 'abierto'
  );
$$;

-- ---------- Activar RLS en TODAS las tablas ----------
alter table public.profiles             enable row level security;
alter table public.admin_roles          enable row level security;
alter table public.consent_versions     enable row level security;
alter table public.consents             enable row level security;
alter table public.survey_periods       enable row level security;
alter table public.surveys              enable row level security;
alter table public.questions            enable row level security;
alter table public.activity_answers     enable row level security;
alter table public.emission_factors     enable row level security;
alter table public.calculations         enable row level security;
alter table public.calculation_details  enable row level security;
alter table public.data_requests        enable row level security;
alter table public.admin_audit_log      enable row level security;

-- El rol 'anon' (usuario sin sesión) no necesita tocar nada.
revoke all on all tables in schema public from anon;

-- ---------- profiles ----------
create policy "perfil: leer el propio" on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy "perfil: crear el propio" on public.profiles
  for insert to authenticated with check (id = (select auth.uid()));
create policy "perfil: editar el propio" on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- ---------- admin_roles ----------
-- SIN políticas a propósito: ningún usuario puede leerla ni escribirla.
-- Solo es_admin() (definer) y service_role (servidor) acceden.

-- ---------- catálogos de lectura (consentimiento, periodos, preguntas) ----------
create policy "aviso: ver versiones activas" on public.consent_versions
  for select to authenticated using (active or public.es_admin());
create policy "periodos: ver" on public.survey_periods
  for select to authenticated using (status <> 'borrador' or public.es_admin());
create policy "periodos: gestionar (admin ambiental)" on public.survey_periods
  for all to authenticated
  using (public.es_admin('ambiental')) with check (public.es_admin('ambiental'));
create policy "preguntas: ver" on public.questions
  for select to authenticated using (true);

-- ---------- consents ----------
create policy "consent: ver los propios" on public.consents
  for select to authenticated using (profile_id = (select auth.uid()));
create policy "consent: aceptar" on public.consents
  for insert to authenticated with check (profile_id = (select auth.uid()));
create policy "consent: revocar" on public.consents
  for update to authenticated
  using (profile_id = (select auth.uid())) with check (profile_id = (select auth.uid()));

-- ---------- surveys ----------
create policy "encuesta: ver las propias" on public.surveys
  for select to authenticated using (profile_id = (select auth.uid()));
-- RF-01: sin consentimiento NO se puede crear una respuesta identificable.
create policy "encuesta: crear (con consentimiento y periodo abierto)" on public.surveys
  for insert to authenticated
  with check (
    profile_id = (select auth.uid())
    and public.tiene_consentimiento()
    and exists (select 1 from public.survey_periods p where p.id = period_id and p.status = 'abierto')
  );
create policy "encuesta: editar la propia mientras es borrador" on public.surveys
  for update to authenticated
  using (profile_id = (select auth.uid()) and status = 'borrador')
  with check (profile_id = (select auth.uid()));

-- ---------- activity_answers ----------
create policy "respuestas: ver las propias" on public.activity_answers
  for select to authenticated
  using (exists (select 1 from public.surveys s
                 where s.id = survey_id and s.profile_id = (select auth.uid())));
create policy "respuestas: escribir si la encuesta es editable" on public.activity_answers
  for insert to authenticated with check (public.encuesta_editable(survey_id));
create policy "respuestas: modificar si la encuesta es editable" on public.activity_answers
  for update to authenticated
  using (public.encuesta_editable(survey_id)) with check (public.encuesta_editable(survey_id));
create policy "respuestas: borrar si la encuesta es editable" on public.activity_answers
  for delete to authenticated using (public.encuesta_editable(survey_id));

-- ---------- emission_factors ----------
-- Los participantes los leen (el informe muestra fuentes); solo el admin ambiental los modifica.
create policy "factores: ver" on public.emission_factors
  for select to authenticated using (true);
create policy "factores: crear (admin ambiental)" on public.emission_factors
  for insert to authenticated with check (public.es_admin('ambiental'));
create policy "factores: editar (admin ambiental)" on public.emission_factors
  for update to authenticated
  using (public.es_admin('ambiental')) with check (public.es_admin('ambiental'));

-- ---------- calculations / calculation_details ----------
-- Solo lectura de lo propio. NO hay política de INSERT: los resultados
-- solo se escriben con la función calcular_huella() (definer), así
-- nadie puede falsificar su resultado desde el navegador.
create policy "calculo: ver los propios" on public.calculations
  for select to authenticated
  using (exists (select 1 from public.surveys s
                 where s.id = survey_id and s.profile_id = (select auth.uid())));
create policy "detalle: ver los propios" on public.calculation_details
  for select to authenticated
  using (exists (select 1 from public.calculations c
                 join public.surveys s on s.id = c.survey_id
                 where c.id = calculation_id and s.profile_id = (select auth.uid())));

-- ---------- data_requests (RF-09) ----------
create policy "solicitud: ver las propias" on public.data_requests
  for select to authenticated using (profile_id = (select auth.uid()));
create policy "solicitud: crear la propia" on public.data_requests
  for insert to authenticated with check (profile_id = (select auth.uid()));
create policy "solicitud: gestionar (admin)" on public.data_requests
  for update to authenticated
  using (public.es_admin()) with check (public.es_admin());
create policy "solicitud: ver todas (admin)" on public.data_requests
  for select to authenticated using (public.es_admin());

-- ---------- admin_audit_log ----------
create policy "auditoria: leer (admin)" on public.admin_audit_log
  for select to authenticated using (public.es_admin());
-- Sin política de INSERT/UPDATE/DELETE: solo el trigger (definer) escribe.
