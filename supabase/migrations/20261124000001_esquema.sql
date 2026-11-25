-- =====================================================================
-- HuellaViva UAN (prototipo académico)
-- Migración 1: esquema, catálogo de preguntas, validaciones y auditoría
-- =====================================================================
-- Convención: los nombres de tablas van en inglés (como propone la guía)
-- y los comentarios en español para facilitar el estudio.
-- ---------------------------------------------------------------------

-- ---------- 1. TIPOS ENUMERADOS ----------
-- Un enum limita los valores posibles a nivel de base de datos
-- (más seguro que confiar solo en el frontend).
create type tipo_usuario   as enum ('estudiante', 'profesor', 'administrativo');
create type estado_periodo as enum ('borrador', 'abierto', 'cerrado');
create type estado_encuesta as enum ('borrador', 'enviada');
create type rol_admin      as enum ('ambiental', 'tecnico');
create type tipo_solicitud as enum ('correccion', 'supresion', 'retiro');
create type estado_solicitud as enum ('recibida', 'en_proceso', 'resuelta', 'rechazada');

-- ---------- 2. PERFILES ----------
-- Perfil mínimo: NO se guarda documento, dirección ni nada innecesario.
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  tipo_usuario tipo_usuario not null,
  campus       text,                          -- opcional (minimización)
  estado       text not null default 'activo' check (estado in ('activo','retirado')),
  created_at   timestamptz not null default now()
);

-- ---------- 3. ROLES ADMINISTRATIVOS ----------
-- El rol NO vive en profiles (el usuario podría editarlo).
-- Esta tabla no tiene políticas para usuarios: solo la función
-- es_admin() (SECURITY DEFINER) la puede leer. Se llena desde el
-- panel de Supabase o con service_role en el servidor, nunca desde el navegador.
create table public.admin_roles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  rol        rol_admin not null,
  created_at timestamptz not null default now()
);

-- ---------- 4. CONSENTIMIENTO ----------
create table public.consent_versions (
  id          uuid primary key default gen_random_uuid(),
  version     text not null unique,           -- ej. 'v1.0-borrador'
  texto       text not null,                  -- texto o URL del aviso mostrado
  purpose     text not null,                  -- finalidad informada
  valid_from  date not null,
  active      boolean not null default false
);

create table public.consents (
  id                 uuid primary key default gen_random_uuid(),
  profile_id         uuid not null references public.profiles(id) on delete cascade,
  consent_version_id uuid not null references public.consent_versions(id),
  accepted_at        timestamptz not null default now(),
  revoked_at         timestamptz,
  unique (profile_id, consent_version_id)
);

-- ---------- 5. PERIODOS Y ENCUESTAS ----------
create table public.survey_periods (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null,         -- ej. 'Octubre 2026'
  start_date           date not null,
  end_date             date not null,
  methodology_version  text not null,         -- ej. 'm1.0'
  status               estado_periodo not null default 'borrador',
  check (end_date >= start_date)
);

create table public.surveys (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null references public.profiles(id) on delete cascade,
  period_id    uuid not null references public.survey_periods(id),
  status       estado_encuesta not null default 'borrador',
  submitted_at timestamptz,
  updated_at   timestamptz not null default now(),
  unique (profile_id, period_id)              -- una encuesta por persona y periodo
);
create index surveys_period_idx on public.surveys(period_id);

-- ---------- 6. CATÁLOGO DE PREGUNTAS ----------
-- Fuente única de verdad para códigos, unidades y rangos de validación.
create table public.questions (
  code           text primary key,            -- 'A1', 'C2', ...
  category       text not null check (category in ('electricidad','gas','transporte','aviacion')),
  description    text not null,
  unit           text,
  min_value      numeric,
  max_value      numeric,
  allowed_values text[],                      -- para preguntas de opción
  required       boolean not null default false
);

insert into public.questions (code, category, description, unit, min_value, max_value, allowed_values, required) values
 ('A1','electricidad','Consumo de electricidad del hogar en el mes','kWh',0,5000,null,true),
 ('A2','electricidad','Valor pagado por electricidad (NO se usa en el cálculo v1; pendiente de solicitud de cambio)','COP',0,5000000,null,false),
 ('A3','electricidad','Personas que comparten el consumo eléctrico','personas',1,15,null,true),
 ('B1','gas','Combustible de cocina','tipo',null,null,array['natural','glp'],false),
 ('B2','gas','Cantidad de combustible consumida en el mes','unidad_combustible',0,1000,null,false),
 ('B3','gas','Personas que comparten el consumo de gas','personas',1,15,null,false),
 ('C1','transporte','Días de asistencia presencial en el mes','dias',0,31,null,true),
 ('C2','transporte','Medio de transporte del tramo','modo',null,null,
     array['caminata','bicicleta','bus','sitp_transmilenio','carro','moto','taxi_app','metro'],false),
 ('C3','transporte','Distancia ida y vuelta del tramo (valor representativo del rango elegido)','km',0,200,null,false),
 ('D1','aviacion','Número de trayectos aéreos en el mes','trayectos',0,60,null,false),
 ('D2','aviacion','Tipo de recorrido del trayecto','tipo',null,null,
     array['nacional_corto','nacional_largo','internacional'],false);

-- ---------- 7. RESPUESTAS ----------
create table public.activity_answers (
  id            uuid primary key default gen_random_uuid(),
  survey_id     uuid not null references public.surveys(id) on delete cascade,
  question_code text not null references public.questions(code),
  item_index    smallint not null default 1,  -- tramo/trayecto 1, 2, 3...
  numeric_value numeric,
  text_value    text,
  unit          text,                         -- la rellena el trigger desde questions
  is_estimated  boolean not null default false, -- dato medido vs. estimado
  unique (survey_id, question_code, item_index),
  check (numeric_value is not null or text_value is not null)
);

-- Trigger: valida rango/valores permitidos y fija la unidad oficial.
create or replace function public.validar_respuesta()
returns trigger language plpgsql as $$
declare q public.questions%rowtype;
begin
  select * into q from public.questions where code = new.question_code;

  if new.numeric_value is not null and (
       (q.min_value is not null and new.numeric_value < q.min_value) or
       (q.max_value is not null and new.numeric_value > q.max_value)) then
    raise exception 'Valor fuera de rango para %: % (permitido % a %)',
      q.code, new.numeric_value, q.min_value, q.max_value;
  end if;

  if new.text_value is not null and q.allowed_values is not null
     and not (new.text_value = any(q.allowed_values)) then
    raise exception 'Valor no permitido para %: %', q.code, new.text_value;
  end if;

  new.unit := q.unit;                         -- evita unidades inconsistentes
  return new;
end $$;

create trigger trg_validar_respuesta
before insert or update on public.activity_answers
for each row execute function public.validar_respuesta();

-- ---------- 8. FACTORES DE EMISIÓN VERSIONADOS ----------
-- factor_key conecta la actividad con su factor (ej. 'electricidad_sin',
-- 'gas_natural', 'transporte_bus', 'avion_internacional').
create table public.emission_factors (
  id            uuid primary key default gen_random_uuid(),
  factor_key    text not null,
  category      text not null,
  factor_value  numeric not null check (factor_value >= 0),
  unit_activity text not null,                -- ej. 'kWh', 'km'
  unit_emission text not null default 'kgCO2e',
  geography     text not null default 'Colombia',
  source        text not null,                -- ej. 'UPME'
  source_url    text,
  reference_year int,
  valid_from    date not null,
  valid_to      date,
  version       int not null default 1,
  approved_by   uuid references auth.users(id),
  justificacion text,                         -- RF-07: motivo del cambio
  is_placeholder boolean not null default false, -- TRUE = valor de prueba, NO oficial
  loaded_at     timestamptz not null default now(),
  unique (factor_key, version)
);

-- Regla de la guía: "no sobrescribir un factor ya usado por cálculos".
-- Si ya fue usado, hay que crear una NUEVA versión.
-- SECURITY DEFINER: necesario para que la comprobación vea TODOS los cálculos,
-- no solo los que el usuario que edita puede leer por RLS (bug hallado en las pruebas).
create or replace function public.proteger_factor_usado()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.calculation_details d where d.factor_id = old.id)
     and (new.factor_value  is distinct from old.factor_value
       or new.unit_activity is distinct from old.unit_activity
       or new.factor_key    is distinct from old.factor_key) then
    raise exception 'Factor % ya fue usado en cálculos: cree una nueva versión', old.factor_key;
  end if;
  return new;
end $$;

-- ---------- 9. CÁLCULOS ----------
create table public.calculations (
  id                  uuid primary key default gen_random_uuid(),
  survey_id           uuid not null references public.surveys(id) on delete cascade,
  methodology_version text not null,
  total_kgco2e        numeric not null default 0,
  calculated_at       timestamptz not null default now()
);
create index calculations_survey_idx on public.calculations(survey_id, calculated_at desc);

create table public.calculation_details (
  id              uuid primary key default gen_random_uuid(),
  calculation_id  uuid not null references public.calculations(id) on delete cascade,
  answer_id       uuid not null references public.activity_answers(id) on delete cascade,
  factor_id       uuid not null references public.emission_factors(id),
  activity_value  numeric not null,           -- dato original
  converted_value numeric not null,           -- tras dividir por hogar o multiplicar por días
  emissions_kgco2e numeric not null
);
create index calc_details_calc_idx on public.calculation_details(calculation_id);

-- el trigger se crea aquí porque ya existe calculation_details
create trigger trg_proteger_factor
before update on public.emission_factors
for each row execute function public.proteger_factor_usado();

-- ---------- 10. SOLICITUDES DE CORRECCIÓN/SUPRESIÓN (RF-09) ----------
create table public.data_requests (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  tipo        tipo_solicitud not null,
  detalle     text,
  estado      estado_solicitud not null default 'recibida',
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);

-- ---------- 11. AUDITORÍA ADMINISTRATIVA ----------
create table public.admin_audit_log (
  id         bigint generated always as identity primary key,
  actor_id   uuid,
  action     text not null,
  entity     text not null,
  entity_id  uuid,
  before_json jsonb,
  after_json  jsonb,
  created_at timestamptz not null default now()
);

-- Trigger genérico: registra quién cambió qué. SECURITY DEFINER para que
-- pueda escribir en la bitácora aunque el usuario no tenga permiso directo.
create or replace function public.auditar_cambio()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.admin_audit_log(actor_id, action, entity, entity_id, before_json, after_json)
  values (auth.uid(), tg_op, tg_table_name,
          coalesce((to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid),
          to_jsonb(old), to_jsonb(new));
  return coalesce(new, old);
end $$;

create trigger trg_audit_factors after insert or update or delete on public.emission_factors
for each row execute function public.auditar_cambio();
create trigger trg_audit_periods after insert or update or delete on public.survey_periods
for each row execute function public.auditar_cambio();
