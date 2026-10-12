# SurcoVisor: piloto web real para Ecuador

## Objetivo y alcance
Completar una web con cuentas reales, explotaciones separadas, fincas, parcelas geográficas, campañas, labores, fotos privadas, meteorología por ubicación y NDVI con histórico. Español, USD, hectáreas, mm, °C; zona de finca America/Guayaquil por defecto y Pacific/Galapagos seleccionable. Sin app móvil, sensores, facturación, diagnóstico agronómico ni datos inventados. La demo pública anterior permanece independiente. Repositorios nuevos y vacíos, clonados en carpetas hermanas agroVisorFront y agroVisorBack.

## Arquitectura elegida
- Frontend: React + TypeScript + Vite, React Router, TanStack Query, Leaflet para mapa y dibujo/importación GeoJSON, formularios con validación. Recuperar paleta/estructura de la demo local ../web/dist, nunca las imágenes conceptuales como mapas reales.
- Backend: Node.js LTS + TypeScript + Fastify, JSON Schema/Zod para validación y contrato OpenAPI. API REST /api/v1. Supabase Auth verifica usuarios; acceso de datos con cliente Supabase por solicitud usando JWT del usuario, manteniendo RLS. Claves privilegiadas solo para procesamiento interno.
- Persistencia: Supabase PostgreSQL + PostGIS, Auth, Storage privado. Migraciones SQL en backend y configuración local Supabase. No Redis para el piloto: tabla de trabajos con reclamación atómica, idempotencia y reintentos; worker del backend.
- Despliegue propuesto: frontend estático y backend/worker en Render; Supabase gestionado. Entregar Dockerfile, configuración de despliegue y guía reproducible. No contratar servicios, crear cuentas ni desplegar datos reales sin configuración del propietario. Desarrollo local y pruebas primero.
- Fuentes: Open-Meteo (pronóstico y variables actuales modeladas), Copernicus Data Space Sentinel Hub Statistical/Process API para Sentinel-2 L2A. URLs de proveedores fijas/configurables por servidor, nunca proporcionadas libremente por usuarios.

## Tablas y aislamiento
UUID, timestamps UTC y organización propietaria en toda entidad de negocio. FK compuestas o validación equivalente para impedir referencias entre organizaciones. RLS en tablas y almacenamiento. Índices por organización, padres/fechas, geometría GiST y claves de trabajos.
- profiles: id enlazado a auth.users, nombre, idioma.
- organizations y memberships: explotación/empresa y miembros; owner/editor/viewer. Crear organización y primer propietario atómicamente, sin posibilidad de autoascender mediante cambios de membership.
- farms: organization_id, nombre, ubicación, zona horaria.
- parcels: organization_id, farm_id, nombre, geometría MultiPolygon EPSG:4326, área calculada geodésicamente con PostGIS, geometry_version. Validar coordenadas, geometría válida y superficie positiva. Cambio de geometría versiona/invalida derivados.
- seasons: parcela, cultivo, variedad, inicio/fin, estado; campañas por parcela sin asumir calendario europeo.
- field_events: campaña/parcela, tipo (riego/fertilización/tratamiento/inspección/cosecha/nota), fecha local, notas, producto, dosis y unidad, coste USD, autor. Validar dosis y coste no negativos.
- attachments: evento, objeto privado, MIME, tamaño, autor, estado pendiente/completado. JPEG/PNG/WebP, máximo 10 MB; verificar tamaño/tipo y vinculación autorizada, URLs firmadas de lectura cortas.
- weather_snapshots: finca, ubicación consultada, proveedor, fetched_at, vigencia, payload normalizado; caché 1 hora, conservar último resultado con marca de antigüedad si falla proveedor.
- satellite_observations: parcela, geometry_version, adquisición/intervalo, proveedor, NDVI medio/min/max, proporción válida, estado calidad, referencia raster y versión de procesamiento; unicidad para no duplicar observaciones.
- processing_jobs: organización, parcela/versión, tipo, intervalo solicitado, estado, intentos, disponible_desde, bloqueo/lease, error resumido; reintentos limitados con backoff y recuperación de bloqueos vencidos.
- audit_events: actor, organización, acción, recurso y fecha; no copiar fotos, secretos ni payloads sensibles al log.
No migrar automáticamente los datos ficticios de localStorage. Fixtures solo en pruebas/desarrollo explícitos.

## API y recorridos
- /me, /organizations y membresía consultable; login, registro, confirmación, cierre y recuperación mediante Supabase Auth. Onboarding crea organización y primera finca. No necesita interfaz de invitaciones en esta primera entrega; los roles sí quedan preparados y probados.
- CRUD autenticado /farms, /parcels, /seasons, /events; listados paginados y filtrados. Archivar fincas/parcelas con historial en vez de eliminar en cascada eventos. Exportación CSV autorizada y protegida contra fórmulas.
- /events/:id/attachments para iniciar/finalizar carga y lectura firmada. Nunca aceptar una ruta de almacenamiento ajena al usuario/organización/evento.
- /farms/:id/weather con fuente, coordenadas, zona, hora y estado fresco/antiguo/no disponible.
- /parcels/:id/ndvi, /parcels/:id/ndvi/refresh y /jobs/:id. Refresco encola y responde 202; deduplicación por parcela/geometría/intervalo. Histórico inicial 90 días, reconsulta incremental diaria mediante worker/scheduler. Respetar límites y errores 429 del proveedor.
- NDVI=(B08-B04)/(B08+B04), excluyendo no-data, denominador cero y clases SCL inválidas/nubes/sombras. Conservar cobertura válida; aceptar para comparación >=70% como umbral técnico configurable. Mostrar explícitamente falta de observaciones válidas, algo frecuente por nubosidad. Nunca reemplazar fallos con valores simulados.
- Mapa NDVI georreferenciado para observación seleccionada mediante Process API con máscara, fecha/intervalo coherente y bounds del lote; estadísticos e imagen deben documentar misma ventana/mosaico, no prometer adquisición única si no se garantiza. Si falta configuración, devolver estado de integración no configurada.
- Todos los endpoints verifican autenticación y pertenencia; 400 validación, 401 sesión, 403 permiso, 404 recurso inaccesible, 409 conflicto, 429 límite, 503 integración. CORS restringido, límites de tamaño y frecuencia, logs con request ID sin tokens.

## Interfaz
Registro/login/recuperación y onboarding; panel sin métricas ficticias; selector finca/parcela; mapa real con dibujo e importación GeoJSON; campañas editables; cuaderno con filtros, fotos y CSV; previsión de siete días; gráfico NDVI con calidad/fecha y estado del procesamiento. Estados carga/vacío/error/sesión vencida y feedback de guardado. Las entidades guardadas se recuperan desde otro navegador. Configuración ausente debe mostrar instrucciones claras y no un falso éxito. Diseño responsive basado en demo, navegación por teclado y formularios accesibles.

## Orden y validación
1. Contrato y migraciones, autenticación/RLS, configuración y CI.
2. CRUD geográfico, campañas y labores; frontend conectado.
3. Fotos privadas y exportación.
4. Clima, caché y estados reales.
5. Worker/NDVI, calidad y mapa histórico.
6. Pruebas, builds, revisión y documentación de despliegue.
Pruebas obligatorias: usuario A no puede acceder/modificar datos ni fotos de B; viewer no escribe; no escalación de rol; FK cruzadas rechazadas; polígonos inválidos y áreas; trabajos deduplicados/reintentables; máscara NDVI/nubes/sin datos; fallos/timeout/429; fechas Ecuador/Galápagos; CSV; login→finca→parcela→campaña→labor→foto y lectura en segunda sesión. Pruebas con proveedores simulados solo en el runner; smoke tests reales separados que requieren credenciales. No declarar completa validación real de satélite, auth o storage si no se ejecutó.

## Entrega y límites externos
Instalar dependencias y guardar lockfiles; .env.example sin secretos; migraciones reproducibles; documentación OpenAPI; README por repo; pruebas unitarias/integración/E2E apropiadas y CI; instrucciones de backup/restore, configuración de emails y producción; reporte exacto de pruebas y bloqueos. Trabajar y dejar cambios en ambos repositorios sin push/merge por ahora. No modificar el sitio demo alojado.
La activación real requiere proyecto Supabase, SMTP de producción, credenciales OAuth CDSE, servicio de mapas con atribución/licencia y plan meteorológico apropiado. Proponer teselas OSM estándar solo para desarrollo/piloto ligero sin descargas masivas; proveedor configurable para producción. No inventar credenciales ni contratar nada. Open-Meteo gratuito sirve para prototipo no comercial; uso comercial requiere plan adecuado. No fijar coste total sin volumen de parcelas, usuarios y frecuencia.

## Fuentes oficiales consultadas 2026-10-03
https://supabase.com/docs/guides/database/extensions/postgis
https://supabase.com/docs/guides/database/postgres/row-level-security
https://documentation.dataspace.copernicus.eu/APIs/SentinelHub/Overview/Authentication.html
https://documentation.dataspace.copernicus.eu/APIs/SentinelHub/Statistical.html
https://open-meteo.com/en/pricing
https://render.com/docs/service-types
