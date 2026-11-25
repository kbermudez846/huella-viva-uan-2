-- =====================================================================
-- Pruebas de RLS y cálculo (ejecutar DESPUÉS de las migraciones y seed.sql)
-- =====================================================================
-- Cómo correrlas (Supabase local):  psql "$DATABASE_URL" -f tests/rls_tests.sql
-- Cada bloque "se hace pasar" por un usuario fijando el rol de Postgres y
-- el JWT (auth.uid() lee el 'sub' del JWT). Si una aserción falla,
-- el script se detiene con un error claro. Todo termina en ROLLBACK,
-- así no queda basura en la base.
-- Perfiles probados: participante, administrador y usuario no autorizado.
-- ---------------------------------------------------------------------
begin;

-- Función auxiliar de prueba: simula iniciar sesión como un usuario
create or replace function pg_temp.login_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims',
         json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

-- =============== 1. PARTICIPANTE (estudiante demo) ===============
select pg_temp.login_como('00000000-0000-0000-0000-000000000001');

do $$
declare n int; v_calc uuid; v_total numeric;
begin
  -- 1.1 Solo ve su propia encuesta
  select count(*) into n from public.surveys;
  assert n = 1, 'El participante debería ver exactamente 1 encuesta (la suya), vio ' || n;

  -- 1.2 Calcular su huella y verificar el valor esperado del seed (9.00)
  v_calc := public.calcular_huella('30000000-0000-0000-0000-000000000001');
  select total_kgco2e into v_total from public.calculations where id = v_calc;
  assert v_total = 9.00, 'Total esperado 9.00, obtenido ' || v_total;

  -- 1.3 Trazabilidad: cada detalle apunta a una respuesta y a un factor
  select count(*) into n from public.calculation_details where calculation_id = v_calc;
  assert n = 2, 'Se esperaban 2 filas de detalle (electricidad y transporte), hubo ' || n;
end $$;

-- 1.4 NO puede escribir un cálculo falso directamente
do $$
begin
  begin
    insert into public.calculations(survey_id, methodology_version, total_kgco2e)
    values ('30000000-0000-0000-0000-000000000001', 'm1.0', 0);
    raise exception 'FALLO: el participante pudo insertar un cálculo';
  exception when insufficient_privilege or others then
    if sqlerrm like 'FALLO%' then raise; end if;  -- éxito: fue bloqueado
  end;
end $$;

-- 1.5 NO puede darse rol de administrador ni leer admin_roles
do $$
declare n int;
begin
  select count(*) into n from public.admin_roles;
  assert n = 0, 'El participante no debería ver admin_roles';
  begin
    perform * from public.dashboard_agregado('20000000-0000-0000-0000-000000000001');
    raise exception 'FALLO: el participante accedió al dashboard';
  exception when others then
    if sqlerrm like 'FALLO%' then raise; end if;
  end;
end $$;

-- 1.6 Validación de datos: valor fuera de rango debe rechazarse
do $$
begin
  begin
    update public.activity_answers set numeric_value = 99999
    where question_code = 'A1';
    raise exception 'FALLO: aceptó 99999 kWh';
  exception when others then
    if sqlerrm like 'FALLO%' then raise; end if;
  end;
end $$;

reset role;

-- =============== 2. OTRO PARTICIPANTE (aislamiento entre usuarios) ===============
select pg_temp.login_como('00000000-0000-0000-0000-000000000002');
do $$
declare n int;
begin
  select count(*) into n from public.surveys;
  assert n = 0, 'El otro estudiante NO debe ver encuestas ajenas, vio ' || n;
  select count(*) into n from public.activity_answers;
  assert n = 0, 'El otro estudiante NO debe ver respuestas ajenas';
  select count(*) into n from public.calculations;
  assert n = 0, 'El otro estudiante NO debe ver cálculos ajenos';
  -- sin consentimiento no puede crear encuesta (RF-01)
  begin
    insert into public.surveys(profile_id, period_id)
    values ('00000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001');
    raise exception 'FALLO: creó encuesta sin consentimiento';
  exception when others then
    if sqlerrm like 'FALLO%' then raise; end if;
  end;
end $$;
reset role;

-- =============== 3. ADMINISTRADOR AMBIENTAL ===============
select pg_temp.login_como('00000000-0000-0000-0000-000000000003');
do $$
declare n int; filas int;
begin
  -- 3.1 NO ve filas individuales
  select count(*) into n from public.surveys;
  assert n = 0, 'El admin no debe leer encuestas individuales';
  select count(*) into n from public.activity_answers;
  assert n = 0, 'El admin no debe leer respuestas individuales';

  -- 3.2 Dashboard: con solo 1 participante, la celda (<10) debe ocultarse
  select count(*) into filas from public.dashboard_agregado('20000000-0000-0000-0000-000000000001');
  assert filas = 0, 'Celdas con menos de 10 respuestas deben ocultarse';

  -- 3.3 Puede crear una nueva versión de factor y queda auditado
  insert into public.emission_factors
    (factor_key, category, factor_value, unit_activity, source, valid_from, version, is_placeholder, justificacion)
  values ('electricidad_sin','electricidad', 0.11, 'kWh', 'PLACEHOLDER', '2026-12-01', 2, true, 'prueba de versionado');
  select count(*) into n from public.admin_audit_log where entity = 'emission_factors';
  assert n >= 1, 'El cambio de factores debe quedar en la bitácora';

  -- 3.4 NO puede modificar un factor que ya fue usado en un cálculo
  begin
    update public.emission_factors set factor_value = 9
    where factor_key = 'electricidad_sin' and version = 1;
    raise exception 'FALLO: modificó un factor ya usado';
  exception when others then
    if sqlerrm like 'FALLO%' then raise; end if;
  end;
end $$;
reset role;

-- =============== 4. USUARIO NO AUTORIZADO (sin sesión / anon) ===============
set local role anon;
do $$
begin
  begin
    perform count(*) from public.surveys;
    raise exception 'FALLO: anon pudo consultar surveys';
  exception when others then
    if sqlerrm like 'FALLO%' then raise; end if;
  end;
  begin
    perform count(*) from public.emission_factors;
    raise exception 'FALLO: anon pudo consultar factores';
  exception when others then
    if sqlerrm like 'FALLO%' then raise; end if;
  end;
end $$;
reset role;

-- =============== 5. USUARIO AUTENTICADO SIN ROL (profesor sin permisos admin) ===============
select pg_temp.login_como('00000000-0000-0000-0000-000000000004');
do $$
begin
  begin
    perform * from public.dashboard_agregado('20000000-0000-0000-0000-000000000001');
    raise exception 'FALLO: usuario sin rol accedió al dashboard';
  exception when others then
    if sqlerrm like 'FALLO%' then raise; end if;
  end;
  begin
    insert into public.emission_factors
      (factor_key, category, factor_value, unit_activity, source, valid_from, version)
    values ('x','x',1,'x','x','2026-01-01',1);
    raise exception 'FALLO: usuario sin rol modificó factores';
  exception when others then
    if sqlerrm like 'FALLO%' then raise; end if;
  end;
end $$;
reset role;

select 'TODAS LAS PRUEBAS PASARON' as resultado;
rollback;
