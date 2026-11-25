-- =====================================================================
-- Migración 4: permisos de tabla mínimos para el rol "authenticated"
-- =====================================================================
-- RLS decide QUÉ FILAS ve cada usuario, pero antes el rol necesita permiso
-- (GRANT) para tocar la tabla. Hallazgo de las pruebas: sin esto la app
-- recibe "permiso denegado". Aquí se da solo lo mínimo necesario.
grant usage on schema public to authenticated;

grant select, insert, update          on public.profiles            to authenticated;
grant select                          on public.consent_versions    to authenticated;
grant select, insert, update          on public.consents            to authenticated;
grant select, insert, update, delete  on public.survey_periods      to authenticated;
grant select, insert, update          on public.surveys             to authenticated;
grant select                          on public.questions           to authenticated;
grant select, insert, update, delete  on public.activity_answers    to authenticated;
grant select, insert, update          on public.emission_factors    to authenticated;
grant select                          on public.calculations        to authenticated;
grant select                          on public.calculation_details to authenticated;
grant select, insert, update          on public.data_requests       to authenticated;
grant select                          on public.admin_audit_log     to authenticated;

-- admin_roles: solo SELECT y SIN políticas RLS, así que ningún usuario ve filas.
grant select                          on public.admin_roles         to authenticated;
