# ContentFlow Infrastructure Inventory

## GitHub
- Repository: `investmentsespana-stack/-contentflow`
- Default branch: `main`
- Role: master source repository, QA, CI/CD, change history

## Vercel
- Team: `ContentFlow` (`content-flow3`)
- Production project: `contentflow-ai`
- Project ID: `prj_zdruVxq7fTPFNsrC14ZZYLJB6QY2`
- Production status: `READY`
- Production URL: `https://contentflow-ai-tan.vercel.app`
- Secondary project: `contentflow-fresh10-monitor`

## Supabase
- Project: `ContentFlow AI`
- Project ref: `koqpyfvnprmirqviafzq`
- Region: `us-east-1`
- Status: `ACTIVE_HEALTHY`
- PostgreSQL: 17

## Active Edge Functions
The live project currently contains the ContentFlow Director, orchestrator, submit/status endpoints, agent teams, builder/worker loops, Fresh-10 recruitment/benchmarking functions, QA triggers, gap planner, director control/repair functions, inventory triggers, and NexoRouter probes.

### Already mirrored into GitHub
- `contentflow-app` (active version 9)

### Migration policy
1. Production remains untouched while code is mirrored.
2. Export active function source into `supabase/functions/<slug>/`.
3. Never commit secrets or service-role keys.
4. Validate exported source against active Supabase function hash/version.
5. Only after source parity is established should GitHub become the deployment source of truth.
6. Browser QA runs independently against production before any deployment wiring is changed.

## Immediate QA objective
`panel_qa_v1_browser`: obtain real runtime evidence in Chromium, Firefox, and WebKit through GitHub Actions and retain Playwright artifacts.
