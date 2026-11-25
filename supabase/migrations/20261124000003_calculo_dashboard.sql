-- =====================================================================
-- Migración 3: cálculo reproducible y dashboard agregado
-- =====================================================================

-- ---------- Factor vigente ----------
-- Devuelve el id del factor más reciente (mayor versión) que estaba
-- vigente en la fecha dada. Usar la fecha de FIN del periodo hace que
-- recalcular un periodo viejo use los factores de ese momento.
create or replace function public.factor_vigente(p_key text, p_fecha date)
returns uuid language sql stable set search_path = public as $$
  select id from public.emission_factors
  where factor_key = p_key
    and valid_from <= p_fecha
    and (valid_to is null or valid_to >= p_fecha)
  order by version desc
  limit 1;
$$;

-- ---------- Cálculo individual (RF-04) ----------
-- Fórmula (documentarla en la sección 10 del documento):
--   electricidad = kWh / personas_hogar            × factor_electricidad
--   gas          = cantidad / personas_hogar       × factor_combustible
--   transporte   = km_ida_vuelta × días_asistencia × factor_modo
--   aviación     = 1 trayecto                      × factor_tipo_recorrido
-- Cada fila de calculation_details guarda: dato, conversión, factor y resultado,
-- por lo que cada cifra se puede reconstruir (criterio de aceptación).
-- LIMITACIÓN CONOCIDA: si falta el factor de una actividad, esa fila NO se
-- calcula. La interfaz debe avisar "sin factor disponible" en el informe
-- (no mostrar 0 como si fuera dato).
create or replace function public.calcular_huella(p_survey_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_profile uuid;
  v_period  uuid;
  v_fecha   date;
  v_meth    text;
  v_calc    uuid;
begin
  -- Seguridad: solo el dueño de la encuesta puede calcularla.
  select s.profile_id, s.period_id into v_profile, v_period
  from surveys s where s.id = p_survey_id;
  if v_profile is null or v_profile <> auth.uid() then
    raise exception 'No autorizado';
  end if;

  select end_date, methodology_version into v_fecha, v_meth
  from survey_periods where id = v_period;

  insert into calculations (survey_id, methodology_version, total_kgco2e)
  values (p_survey_id, v_meth, 0)
  returning id into v_calc;

  -- "base" une todas las categorías en una forma común:
  -- (respuesta, clave de factor, dato original, dato convertido)
  with base as (
    -- Electricidad: se reparte entre las personas del hogar (A3)
    select a.id as answer_id, 'electricidad_sin'::text as factor_key,
           a.numeric_value as activity,
           a.numeric_value / greatest(coalesce(h.numeric_value, 1), 1) as converted
    from activity_answers a
    left join activity_answers h
      on h.survey_id = a.survey_id and h.question_code = 'A3'
    where a.survey_id = p_survey_id and a.question_code = 'A1'
      and a.numeric_value is not null

    union all
    -- Gas: B1 define el combustible, B3 las personas
    select a.id, 'gas_' || c.text_value, a.numeric_value,
           a.numeric_value / greatest(coalesce(h.numeric_value, 1), 1)
    from activity_answers a
    join activity_answers c
      on c.survey_id = a.survey_id and c.question_code = 'B1' and c.text_value is not null
    left join activity_answers h
      on h.survey_id = a.survey_id and h.question_code = 'B3'
    where a.survey_id = p_survey_id and a.question_code = 'B2'
      and a.numeric_value is not null

    union all
    -- Transporte: cada tramo i empareja C2 (modo) con C3 (km); C1 = días
    select k.id, 'transporte_' || m.text_value, k.numeric_value,
           k.numeric_value * coalesce(d.numeric_value, 0)
    from activity_answers k
    join activity_answers m
      on m.survey_id = k.survey_id and m.question_code = 'C2' and m.item_index = k.item_index
    left join activity_answers d
      on d.survey_id = k.survey_id and d.question_code = 'C1'
    where k.survey_id = p_survey_id and k.question_code = 'C3'
      and k.numeric_value is not null

    union all
    -- Aviación: cada fila D2 es un trayecto
    select a.id, 'avion_' || a.text_value, 1, 1
    from activity_answers a
    where a.survey_id = p_survey_id and a.question_code = 'D2'
      and a.text_value is not null
  )
  insert into calculation_details
    (calculation_id, answer_id, factor_id, activity_value, converted_value, emissions_kgco2e)
  select v_calc, b.answer_id, f.id, b.activity, b.converted, b.converted * f.factor_value
  from base b
  join emission_factors f on f.id = public.factor_vigente(b.factor_key, v_fecha);

  update calculations
  set total_kgco2e = coalesce((select sum(emissions_kgco2e)
                               from calculation_details where calculation_id = v_calc), 0)
  where id = v_calc;

  return v_calc;
end $$;

-- Solo usuarios con sesión pueden ejecutarla
revoke all on function public.calcular_huella(uuid) from public, anon;
grant execute on function public.calcular_huella(uuid) to authenticated;

-- ---------- Dashboard agregado (RF-06, RF-10) ----------
-- El administrador NO consulta tablas individuales: solo esta función,
-- que devuelve estadísticos por grupo y categoría y OCULTA celdas con
-- menos de 10 participantes (regla de diseño del proyecto, no umbral legal).
create or replace function public.dashboard_agregado(p_period uuid)
returns table (
  grupo           tipo_usuario,
  categoria       text,
  n_participantes bigint,
  promedio_kgco2e numeric,
  mediana_kgco2e  numeric
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_admin() then
    raise exception 'No autorizado';
  end if;

  return query
  with ultimo as (   -- último cálculo de cada encuesta enviada
    select distinct on (c.survey_id) c.id, c.survey_id
    from calculations c
    join surveys s on s.id = c.survey_id
    where s.period_id = p_period and s.status = 'enviada'
    order by c.survey_id, c.calculated_at desc
  ),
  por_persona as (   -- total por persona y categoría
    select pr.tipo_usuario as g, q.category as cat, sum(d.emissions_kgco2e) as kg
    from ultimo u
    join surveys s on s.id = u.survey_id
    join profiles pr on pr.id = s.profile_id
    join calculation_details d on d.calculation_id = u.id
    join activity_answers a on a.id = d.answer_id
    join questions q on q.code = a.question_code
    group by s.profile_id, pr.tipo_usuario, q.category
  )
  select pp.g, pp.cat, count(*),
         round(avg(pp.kg), 2),
         round((percentile_cont(0.5) within group (order by pp.kg))::numeric, 2)
  from por_persona pp
  group by pp.g, pp.cat
  having count(*) >= 10;      -- regla de agregación mínima
end $$;

revoke all on function public.dashboard_agregado(uuid) from public, anon;
grant execute on function public.dashboard_agregado(uuid) to authenticated;

-- ---------- Tamaño de la muestra (RF-10) ----------
-- Solo cuenta participantes efectivos; NO extrapola a la comunidad.
create or replace function public.muestra_periodo(p_period uuid)
returns table (grupo tipo_usuario, n_participantes bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  return query
  select pr.tipo_usuario, count(*)
  from surveys s join profiles pr on pr.id = s.profile_id
  where s.period_id = p_period and s.status = 'enviada'
  group by pr.tipo_usuario
  having count(*) >= 10;
end $$;

revoke all on function public.muestra_periodo(uuid) from public, anon;
grant execute on function public.muestra_periodo(uuid) to authenticated;
