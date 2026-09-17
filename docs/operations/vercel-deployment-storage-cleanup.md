# Vercel Deployment Storage Cleanup — runbook operativo

## Objetivo

Mantener el proyecto Vercel `contentflow-ai` del team `ContentFlow` (`content-flow3`) por debajo del límite Hobby de **10 GB de Deployment Storage**, sin tocar producción vigente, dominios, variables ni integración GitHub.

## Estado y evidencia conocida

- El aviso de Vercel indicó 100% de Deployment Storage.
- Última cifra observada directamente en el Dashboard antes de continuar la limpieza: **10.41 GB / 10 GB**.
- El fix preventivo ya fue incorporado en PR #119 / commit `5136789257bb...` para evitar que ramas de research/trading/CI sigan generando previews innecesarios; `.vercelignore` excluye artefactos de investigación/trading y `.github`.
- Un primer batch de 11 previews fue eliminado con éxito mediante `npx vercel remove <exact-url> -y` desde PowerShell.
- No asumir que batches posteriores fueron ejecutados si no existe evidencia de terminal o verificación posterior en Vercel.

## Scope correcto

Antes de eliminar nada, confirmar el team/scope:

```powershell
npx vercel switch content-flow3
```

Si responde `No changes made`, el scope ya era el correcto.

## Método de eliminación que funcionó

Eliminar por URL exacta del deployment, no por nombre ambiguo ni usando `vercel api`:

```powershell
npx vercel remove <deployment-url-exacto> -y
```

Ejemplo de patrón:

```powershell
npx vercel remove contentflow-xxxxxxxxx-content-flow3.vercel.app -y
```

Para varios deployments, usar un `.ps1` con una lista explícita de URLs y ejecutar uno por uno. No usar traducciones de `--yes`; `-y` fue la forma elegida para evitar problemas de copy/paste.

## Deployments protegidos — NO BORRAR

Preservar siempre estos deployments:

1. `dpl_9KiJKQ5jdpVR5iXQtfJNmjGFo756`
   - producción actual
   - URL: `contentflow-ahl8cicw1-content-flow3.vercel.app`
   - commit: `3619e4f6bd808a142c8f19f2dca13307e70ccebb`

2. `dpl_Hock782ZkTUo9ZiVDt3xe5ZQYNpR`
   - rollback protegido
   - URL: `contentflow-mwvja2u95-content-flow3.vercel.app`
   - commit: `513678...`

3. `dpl_Hdp1BGZD5aQf8JkKnJq6tXBqXzrz`
   - rollback/manual preserve
   - URL: `contentflow-kpdch1x0y-content-flow3.vercel.app`
   - commit: `32c1e116...`

## Recursos que tampoco se deben tocar

No borrar ni modificar durante esta tarea:

- `www.cygnusacademyai.com`
- `cygnusacademyai.com`
- `www.investmentsespana.space`
- `investmentsespana.space`
- variables de entorno
- integración GitHub
- project `contentflow-ai`
- team `ContentFlow`

## Orden de limpieza

1. Abrir/consultar Vercel Usage y registrar Deployment Storage actual.
2. Listar deployments del proyecto.
3. Excluir de forma explícita los tres deployments protegidos anteriores.
4. Eliminar primero **previews no-production** (`target=null`) antiguos y de ramas research/fix/feature.
5. Ejecutar por batches pequeños y verificar después de cada batch.
6. Refrescar Vercel Usage y registrar el nuevo valor.
7. Repetir hasta que Deployment Storage quede **< 10.00 GB**.
8. Solo si los previews no bastan, evaluar stale production deployments antiguos uno por uno; nunca borrar producción actual ni rollback protegido sin evidencia y autorización adicional.

## Candidatos de preview conocidos para revisar primero

Estos aparecieron como `target=null` en la última revisión y son candidatos preferentes, siempre que sigan existiendo y no hayan sido promovidos/cambiados desde entonces:

- `contentflow-eos1yrhmk-content-flow3.vercel.app`
- `contentflow-onm7oo4lm-content-flow3.vercel.app`
- `contentflow-nto87vq4f-content-flow3.vercel.app`
- `contentflow-qx34ael44-content-flow3.vercel.app`
- `contentflow-h4dtczzma-content-flow3.vercel.app`

No asumir existencia ni seguridad actual: Work debe volver a listar y validar antes de borrar.

## Gate de terminación

La tarea no se considera completada por haber ejecutado comandos. Solo cerrar cuando exista evidencia verificable de:

- Deployment Storage **< 10.00 GB** en Vercel Usage.
- producción actual `dpl_9KiJKQ5jdpVR5iXQtfJNmjGFo756` sigue READY.
- los deployments protegidos siguen presentes.
- los cuatro dominios siguen intactos.
- no se tocaron variables ni GitHub integration.

## Regla truth-first

No reportar “espacio liberado” ni “limpieza terminada” basándose únicamente en `vercel remove`. El valor final debe verificarse en Vercel Usage. Si Vercel tarda en recalcular, reportar `PENDING_RECALCULATION` y volver a verificar después, sin seguir borrando a ciegas.
