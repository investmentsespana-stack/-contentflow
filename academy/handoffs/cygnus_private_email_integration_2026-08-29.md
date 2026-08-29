# Cygnus Academy AI — Private Email integration

Fecha: 2026-08-29
Mailbox institucional: `social@investmentsespana.space`
Estado: `CODE_READY / SECRET_REQUIRED / NOT_YET_RUNTIME_VERIFIED`

## Verificado externamente
Namecheap Private Email usa `mail.privateemail.com` para IMAP/SMTP. Configuración oficial vigente: IMAP 993 SSL/TLS y SMTP 465 SSL/TLS; usuario = dirección completa del mailbox. No almacenar la contraseña en repositorio, issues, logs o chat.

## Implementado
Archivo: `src/platform/private-email-connector.mjs`

Contrato:
- lectura de configuración exclusivamente desde variables de entorno;
- nunca devuelve contraseña en recibos;
- emite solo fingerprint SHA-256 truncado de la credencial;
- configuración IMAP/SMTP TLS;
- verificación IMAP y SMTP en paralelo mediante adapters;
- funciones preparadas para `sendPrivateEmail` y `listPrivateEmailInbox`;
- fail-closed cuando falte address/password/adapters.

## Variables requeridas en producción
- `CYGNUS_EMAIL_ADDRESS=social@investmentsespana.space`
- `CYGNUS_EMAIL_PASSWORD=<SECRET>`
- `CYGNUS_EMAIL_HOST=mail.privateemail.com`
- `CYGNUS_EMAIL_IMAP_PORT=993`
- `CYGNUS_EMAIL_SMTP_PORT=465`

`CYGNUS_EMAIL_PASSWORD` debe introducirse directamente en el gestor de secretos del runtime. No copiarla al repositorio ni al chat.

## Gate de certificación pendiente
1. Inyectar el secreto en runtime.
2. Conectar adapters IMAP/SMTP reales.
3. Ejecutar verificación bidireccional.
4. Confirmar lectura del mensaje de prueba ya recibido.
5. Enviar desde `social@investmentsespana.space` a Gmail y confirmar recepción.
6. Solo entonces pasar a `CONNECTED / VERIFIED`.

## Guardrails
- Cero secretos en GitHub/chat/logs.
- TLS obligatorio.
- No borrar correo durante pruebas.
- No activar automatizaciones de respuesta masiva hasta certificar envío/recepción.
- Mantener aliases institucionales como recepción; el mailbox operativo principal es `social@investmentsespana.space`.
