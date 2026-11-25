# HuellaViva UAN

Prototipo académico para estimar la huella de carbono mensual de la comunidad universitaria
(Universidad Antonio Nariño). Trabajo final integrador de **Gestión de Requisitos + Mecanismos de
Persistencia de Software**.

> **Aviso:** estimador educativo. No es un inventario institucional verificado, una certificación,
> una compensación de emisiones ni un resultado oficial de RENARE. Los factores de emisión de la
> demostración son **valores de prueba** (`is_placeholder = true`) y deben sustituirse por factores
> oficiales (UPME/FECOC) antes de presentar cifras como reales.

**Autor:** Kevin Bermudez · **Demo:** _(enlace de Vercel)_ · **Uso:** académico, con datos solo sintéticos.

## Qué hace
- Participante: cuenta, elección de grupo, consentimiento informado, encuesta mensual, informe individual
  (total, desglose, factores, fuentes, limitaciones) y solicitudes de corrección o supresión.
- Administrador ambiental: dashboard agregado (oculta grupos con menos de 10 respuestas), tamaño de la
  muestra y exportación CSV de agregados.
- Base de datos: factores versionados, cálculo reproducible, auditoría y RLS.

## Estructura
```
README.md
docs/                      documento de análisis y diseño, presentación, capturas
src/                       aplicación web (index.html, config.js, config.example.js)
supabase/migrations/       SQL versionado (ejecutar en orden)
supabase/seed.sql          datos SINTÉTICOS de prueba
tests/rls_tests.sql        pruebas de RLS y cálculo (5 perfiles)
.gitignore
```

## Instalación
1. Crea un proyecto en [Supabase](https://supabase.com).
2. En **SQL Editor**, ejecuta en orden cada archivo de `supabase/migrations/`
   (esquema, RLS, cálculo y dashboard, permisos). Una vez cada uno.
3. Opcional, para probar: ejecuta `supabase/seed.sql` y luego `tests/rls_tests.sql`.
   Resultado esperado: `TODAS LAS PRUEBAS PASARON`.
4. En `src/`, copia `config.example.js` como `config.js` y escribe la URL del proyecto y la clave
   **publicable** (Project Settings > API Keys).
5. Sirve la carpeta `src/` con un servidor local (por ejemplo la extensión Live Server de VS Code).
6. En **Authentication > Sign In / Providers > Email**, desactiva "Confirm email" mientras pruebas.
7. Para ser administrador, inserta tu UUID en `admin_roles`:
   ```sql
   insert into public.admin_roles (user_id, rol) values ('TU-UUID', 'ambiental');
   ```

## Variables y secretos
Solo se usan la URL del proyecto y la clave publicable, en `src/config.js`. Esa clave puede ir en el
navegador porque todas las tablas tienen RLS. **Nunca** se usan ni se publican la clave `secret` ni
`service_role`. No se suben archivos `.env`.

## Seguridad y privacidad (resumen)
- RLS en todas las tablas; el rol administrativo vive en `admin_roles`, sin políticas para usuarios.
- Los cálculos solo los escribe la función `calcular_huella`; el dashboard solo usa funciones agregadas.
- Minimización: sin documento, dirección ni placa; distancias por rangos.
- El aviso de consentimiento es un borrador pendiente de validación institucional.

## Limitaciones
Factores de prueba; sin alimentación, bienes ni residuos; un tramo de transporte y un trayecto aéreo por
encuesta; gestión de factores y solicitudes por SQL; sin denominador de población invitada.
