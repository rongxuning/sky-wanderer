import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { createAuthService, emptyStore, type AuthStore } from "./auth-service.ts";
import { handleAuthRequest } from "./http.ts";

const port = Number(process.env.PORT ?? "8787");
const dataFile = process.env.DATA_FILE ?? "data/auth-store.json";

function readStore(path: string): AuthStore {
  if (!existsSync(path)) return emptyStore();
  const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<AuthStore>;
  return {
    users: parsed.users ?? [],
    identities: parsed.identities ?? [],
    sessions: parsed.sessions ?? [],
    records: parsed.records ?? [],
  };
}

const store = readStore(dataFile);
const auth = createAuthService(store, {
  onChange() {
    mkdirSync(dirname(dataFile), { recursive: true });
    writeFileSync(dataFile, `${JSON.stringify(store, null, 2)}\n`);
  },
});

const server = createServer((req, res) => {
  void handleAuthRequest(auth, req, res);
});

server.listen(port, () => {
  process.stdout.write(`sky auth listening on ${port}\n`);
});
