-- =====================================================================
-- seed.sql: SOLO DATOS SINTÉTICOS (la guía prohíbe datos reales en GitHub)
-- =====================================================================
-- IMPORTANTE sobre los factores:
--   Los valores de abajo son NÚMEROS DE PRUEBA (is_placeholder = true) para
--   poder probar el cálculo. NO son oficiales. Antes de usar la app de
--   verdad, reemplácenlos por factores de UPME/FECOC u otra fuente
--   reconocida, creando una NUEVA versión de cada uno (version = 2)
--   con fuente, URL, año y fecha de consulta reales.
-- ---------------------------------------------------------------------

-- ---------- Usuarios ficticios (auth.users) ----------
-- En Supabase local esto funciona en el seed. Los UUID son inventados.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'estudiante.demo@example.com'),
  ('00000000-0000-0000-0000-000000000002', 'estudiante.otro@example.com'),
  ('00000000-0000-0000-0000-000000000003', 'admin.ambiental@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'sin.permisos@example.com')
on conflict (id) do nothing;

insert into public.profiles (id, tipo_usuario, campus) values
  ('00000000-0000-0000-0000-000000000001', 'estudiante', 'Campus Demo'),
  ('00000000-0000-0000-0000-000000000002', 'estudiante', 'Campus Demo'),
  ('00000000-0000-0000-0000-000000000004', 'profesor',   null)
on conflict (id) do nothing;

-- Rol administrativo (en producción se asigna desde el panel/servidor)
insert into public.admin_roles (user_id, rol)
values ('00000000-0000-0000-0000-000000000003', 'ambiental')
on conflict (user_id) do nothing;

-- ---------- Consentimiento (BORRADOR: debe revisarlo la instancia institucional) ----------
insert into public.consent_versions (id, version, texto, purpose, valid_from, active) values
  ('10000000-0000-0000-0000-000000000001', 'v1.0-borrador',
   'Texto de ejemplo del prototipo. La institución debe identificar al responsable y validar el aviso.',
   'Estimar la huella de carbono individual y generar estadísticas agregadas',
   '2026-11-01', true)
on conflict (id) do nothing;

-- ---------- Periodo ----------
insert into public.survey_periods (id, name, start_date, end_date, methodology_version, status) values
  ('20000000-0000-0000-0000-000000000001', 'Noviembre 2026 (demo)',
   '2026-11-01', '2026-11-30', 'm1.0', 'abierto')
on conflict (id) do nothing;

-- ---------- Factores de PRUEBA (no oficiales) ----------
insert into public.emission_factors
  (factor_key, category, factor_value, unit_activity, source, reference_year, valid_from, version, is_placeholder, justificacion)
values
  ('electricidad_sin',      'electricidad', 0.10, 'kWh',            'PLACEHOLDER - reemplazar con UPME (SIN)', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('gas_natural',           'gas',          2.00, 'unidad',         'PLACEHOLDER - reemplazar con UPME (FECOC)', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('gas_glp',               'gas',          3.00, 'unidad',         'PLACEHOLDER - reemplazar con UPME (FECOC)', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('transporte_caminata',   'transporte',   0.00, 'km',             'PLACEHOLDER', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('transporte_bicicleta',  'transporte',   0.00, 'km',             'PLACEHOLDER', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('transporte_bus',        'transporte',   0.05, 'km',             'PLACEHOLDER', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('transporte_sitp_transmilenio','transporte',0.04,'km',           'PLACEHOLDER', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('transporte_carro',      'transporte',   0.20, 'km',             'PLACEHOLDER', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('transporte_moto',       'transporte',   0.10, 'km',             'PLACEHOLDER', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('transporte_taxi_app',   'transporte',   0.20, 'km',             'PLACEHOLDER', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('transporte_metro',      'transporte',   0.03, 'km',             'PLACEHOLDER', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('avion_nacional_corto',  'aviacion',     50.0, 'trayecto',       'PLACEHOLDER', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('avion_nacional_largo',  'aviacion',     90.0, 'trayecto',       'PLACEHOLDER', 2026, '2026-01-01', 1, true, 'valor de prueba'),
  ('avion_internacional',   'aviacion',    400.0, 'trayecto',       'PLACEHOLDER', 2026, '2026-01-01', 1, true, 'valor de prueba')
on conflict (factor_key, version) do nothing;

-- ---------- Consentimiento y encuesta sintética del estudiante demo ----------
insert into public.consents (profile_id, consent_version_id)
values ('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001')
on conflict do nothing;

insert into public.surveys (id, profile_id, period_id, status) values
  ('30000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
   '20000000-0000-0000-0000-000000000001', 'borrador')
on conflict (id) do nothing;

-- Caso de ejemplo para verificar a mano (con factores de prueba):
--   Electricidad: 120 kWh / 4 personas = 30 kWh  × 0.10 = 3.00
--   Transporte: bus, 10 km × 12 días = 120 km    × 0.05 = 6.00
--   Total esperado = 9.00 kgCO2e
insert into public.activity_answers (survey_id, question_code, item_index, numeric_value, text_value, is_estimated) values
  ('30000000-0000-0000-0000-000000000001', 'A1', 1, 120, null, false),
  ('30000000-0000-0000-0000-000000000001', 'A3', 1, 4,   null, false),
  ('30000000-0000-0000-0000-000000000001', 'C1', 1, 12,  null, false),
  ('30000000-0000-0000-0000-000000000001', 'C2', 1, null, 'bus', false),
  ('30000000-0000-0000-0000-000000000001', 'C3', 1, 10,  null, true)
on conflict do nothing;
