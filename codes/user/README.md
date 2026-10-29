# 账号

一个用户可以绑定手机号、微信、Google。同一种身份再次登录会回到原来的用户。把已经属于别人的身份绑到当前账号上时，合并进更早创建的那个账号，后创建的账号标记为停用。

HTTP 不在这个目录里启动。入口是 `codes/core`，路由说明在 [docs/architecture-backend.md](../../docs/architecture-backend.md)。

迁移文件是 `migrations/001_auth.sql`。`DATABASE_URL` 用 Neon 的 pooled URL；有 `DATABASE_URL_UNPOOLED` 时，迁移走 direct URL。`AUTH_DEMO=1` 且没有 `DATABASE_URL` 时，数据写到 `DATA_FILE`（默认 `data/auth-store.json`）。

只有 `AUTH_DEMO=1` 才接受演示码 `SKY-LOCAL`。生产模式的微信登录要授权码，Google 要 ID token 或授权码。变量见 [../env.sample](../env.sample)。
