import type { D1Migration } from "cloudflare:test";

declare global {
  namespace Cloudflare {
    interface Env {
      DB: D1Database;
      ADMIN_CODE: string;
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}
