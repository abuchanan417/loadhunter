# loadhunter-sync

Server piece of Load Hunter. Runs on Render as a Web Service (Root Directory: `sync`).

Pulls from ISAAC every minute (positions, odometer, engine hours), every 5 minutes (hours of service),
every 6 hours (vehicle and operator lists) and writes to Supabase:

- `trucks` (last position, odometer, ISAAC details), `truck_positions` (history), `driver_hos`
- `app_docs` → `data/company/feeds`, which the app's planner reads live

Environment variables (Render → Environment):

| Name | Value |
| --- | --- |
| ISAAC_USER | ISAAC API user name |
| ISAAC_PASS | ISAAC API password |
| ISAAC_AUTH | ISAAC "Authorization Code" (the long base64 string) |
| ISAAC_API | `https://ct697.isaachosting.ca/isaacapi` |
| ISAAC_TOKEN_URL | `https://auth.isaachosting.ca/IdentityServer/identity/connect/token` |
| SUPABASE_URL | `https://opogyzzqydxaljduafpl.supabase.co` |
| SUPABASE_SERVICE_KEY | Supabase secret key (`sb_secret_...`), never the publishable one |
| SYNC_SECRET | any long random string; protects `/sync` and `/token-test` |

Endpoints: `/health`, `/status`, `POST /sync?secret=...&what=all|fleet|positions|hos`, `/token-test?secret=...`
