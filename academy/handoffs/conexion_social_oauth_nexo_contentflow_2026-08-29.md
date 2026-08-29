# Conexión social OAuth/API Nexo/ContentFlow — estado diferencial

Fecha: 2026-08-29  
Proyecto: `agent-academy-platform-v1`  
Canal: conexión Facebook Cygnus

## Resultado

Estado global: `PARTIAL / REQUIRES_HUMAN_FOR_OAUTH_AND_SECRETS`.

No se crearon apps ni cuentas. No se copiaron, imprimieron o persistieron contraseñas, cookies, códigos, secretos ni tokens en GitHub/chat/logs.

## Meta — inventario oficial

Se localizaron cinco apps en la sesión Meta autenticada:

| App | ID | Estado | Clasificación |
|---|---:|---|---|
| Cygnus Academy AI-Nexo | `1784797469372306` | Desarrollo; vinculada al negocio `Escuela Digital Latinoamerica`; producto Facebook Login presente | `RECUPERABLE / CANDIDATA OFICIAL` |
| Cygnus Academy AI-Nexo | `1416392730399224` | Desarrollo; sin negocio visible en inventario | `DUPLICADA — NO USAR` |
| Cygnus Academy AI-Nexo | `1361344882716152` | Desarrollo; sin negocio visible en inventario | `DUPLICADA — NO USAR` |
| Gygnus Academy AI-Nexo | `905640328923752` | Desarrollo; nombre con error; sin negocio visible | `DUPLICADA — NO USAR` |
| Cygnus Academy AI-Nexo | `776534722219873` | Desarrollo; sin negocio visible | `DUPLICADA — NO USAR` |

No se eliminó, archivó ni modificó ninguna app. La candidata oficial se fijó por evidencia de vínculo de negocio y configuración existente, no por similitud de nombre.

## OAuth Meta — configuración observada

- App candidata: `1784797469372306`.
- Modo: `Desarrollo`.
- Producto agregado: `Inicio de sesión con Facebook`.
- URI OAuth válida existente: `https://contentflow-ai-tan.vercel.app/api/meta/oauth/callback`.
- Inicio de sesión OAuth web: activo.
- Modo estricto de URI: activo.
- Meta muestra el bloqueo: Facebook Login requiere acceso avanzado; `public_profile` no está en acceso avanzado.
- Pantalla `Permisos y funciones`: llamadas API observadas `0`; no se solicitó revisión de app.
- Permisos/funciones visibles con acceso estándar y 0 llamadas: `Meta oEmbed Read`, `instagram_manage_upcoming_events`, `instagram_business_manage_messages`, `instagram_business_manage_comments`, `instagram_manage_events`, además de permisos de perfil no necesarios observados. No se solicitó acceso avanzado durante esta ronda.
- El producto `API Graph de Instagram` aparece disponible para configurar, pero no agregado.

## Runtime ContentFlow

- Repositorio: `investmentsespana-stack/-contentflow`.
- Vercel team: `ContentFlow` (`team_bfWeKPmeSkp9BSuweNlcD5H0`).
- Proyecto: `contentflow-ai` (`prj_zdruVxq7fTPFNsrC14ZZYLJB6QY2`).
- Producción: deployment `dpl_2hgNZTEezvbo8X71BTZSmM3PCg7s`, commit `26a1469d713f2fd36cb71a3854931cbf0a6ace24`, estado `READY`.
- Conector existente: `src/platform/meta-pages-connector.mjs`, esquema `nexo.meta.pages.connection.v1`, modo `read_only_verification`.
- Callback existente: `api/meta/oauth/callback.js`; recibe código, pero deliberadamente no intercambia ni persiste token.
- Variables Meta en el runtime local de esta ejecución: `META_USER_ACCESS_TOKEN`, `META_GRAPH_VERSION`, `META_PAGE_ID`, `META_PAGE_NAME` no presentes.
- La integración actual no implementa OAuth state verificable, intercambio de código, almacenamiento cifrado, rotación/revocación ni conector operativo de Instagram.

## Cuentas exactas ya verificadas en Meta Business Suite

- Facebook: `Cygnus Academy AI`, asset ID `102575905973808`.
- Instagram: `@cygnusacademyai`, ID observado `17841455070447156`, conectado al activo combinado de Meta.
- Instagram histórico: `@escuelaendigital`, ID observado `17841455707849305`, preservado y no desvinculado.

Estos vínculos de Business Suite no equivalen a un token OAuth concedido a ContentFlow. No se declara OAuth completo sin recibo Graph reproducible.

## Otras redes

No existe en el repositorio un conector OAuth/API operativo para TikTok, YouTube, LinkedIn o X. No se creó ninguna cuenta ni aplicación. Estado: `PREPARADA / REQUIERE INVENTARIO DE CREDENCIALES Y APP OFICIAL` para evitar duplicados.

## Permisos concedidos

`NINGUNO CERTIFICADO PARA UN TOKEN CONTENTFLOW EN ESTA RONDA`.

La pantalla de la app muestra niveles de acceso del producto, pero no constituye evidencia de que un usuario haya concedido esos scopes a un token operativo. Las llamadas API están en 0.

## Requiere intervención humana

1. Confirmar que la app canónica es `1784797469372306` y que las otras cuatro quedan fuera de uso; no eliminarlas todavía.
2. Añadir/configurar `API Graph de Instagram` en esa app y seleccionar exclusivamente scopes mínimos necesarios.
3. Solicitar/obtener acceso avanzado y completar revisión de Meta cuando corresponda.
4. Revelar/inyectar `META_APP_SECRET` directamente en Vercel; nunca en GitHub/chat.
5. Configurar secretos de state y cifrado de tokens en el gestor de secretos del runtime.
6. Completar el consentimiento OAuth como administrador legítimo.
7. Implementar y desplegar intercambio de código, persistencia cifrada, status/refresh/revocation y recibo sin secretos.
8. Ejecutar `/me/accounts` y consulta de la cuenta profesional Instagram; persistir solo IDs, tareas/scopes y huellas redactadas.

## Criterio de cierre

No marcar `COMPLETED` hasta que un recibo reproducible y redactado confirme:

- app `1784797469372306`;
- página `102575905973808`;
- Instagram `17841455070447156`;
- scopes concedidos exactos;
- token almacenado cifrado en el runtime, nunca en GitHub;
- prueba API de lectura exitosa y capacidad de publicación solo si fue autorizada;
- revocación/rotación documentadas.

