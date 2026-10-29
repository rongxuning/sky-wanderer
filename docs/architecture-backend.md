# 后端结构

账号和以后的运动数据走 Go。Node 目录 `codes/server` 已删除。

| 目录 | 现在做什么 | 以后 |
| --- | --- | --- |
| `codes/core` | 进程入口 `codes/core/cmd/api`。监听 `PORT`（没设则 `8787`）。`GET /health`。把 `codes/user` 的登录路由挂上来。 | `codes/core/sport` 增加运动、轨迹、路线。网关启动时读取 `sport.Routes()`。 |
| `codes/user` | 手机号、微信、Google。同一个用户可以有多种身份。绑定一个已经属于别人的身份时，合并进**更早创建**的账号，较新的账号作废（`retiredAt`），不物理删除。 | 保持账号边界。不放分析任务。 |
| `codes/analytics` | 只有说明。 | AI 与数据分析。由 core 在进程内调用，不单独对 iOS 暴露第二套登录。 |

临时部署是 Vercel + Neon，不是同机 `/opt/sky-wanderer`。同机 compose 和 Nginx 暂缓，见 [deploy-sky.md](deploy-sky.md)。

## 跑起来

仓库根：

```bash
go test ./codes/user/ ./codes/core/...
AUTH_DEMO=1 PORT=8787 go run ./codes/core/cmd/api
curl -sS localhost:8787/health
```

`AUTH_DEMO=1` 且没有 `DATABASE_URL` 时，账号写在 `data/auth-store.json`，手机号接受 `SKY-LOCAL`。

接 Neon 时：

1. `DATABASE_URL` 用 **pooled** URL（主机名含 `-pooler`），给普通查询。
2. `DATABASE_URL_UNPOOLED` 用 **direct** URL，给启动时的 SQL 迁移。表结构在 `codes/user/migrations/001_auth.sql`，已执行过的文件名记在 `schema_migrations`。
3. `AUTH_DEMO=0`。
4. 短信、微信、Google 的变量见 `codes/env.sample`。

Vercel 项目根就是本仓库。Go preset 从根上的 `cmd/api/main.go` 找到入口，再按 `vercel.json` 编译，步骤见 [deploy-sky.md](deploy-sky.md)。环境变量与 `deploy/env.sample` 相同。部署本身不在这个改动里做。

iPhone 的 `SKY_API_BASE_URL` 默认仍是 `https://api.sky-wanderer.online`。改指向 Vercel 域名的步骤写在 [deploy-sky.md](deploy-sky.md)。登录界面不改。

## 登录接口

路径和 JSON 与原来的 Node 服务一致，供现在的 iOS 客户端使用。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/health` | 数据库可连时 `{"ok":true}`，否则 503 `db_unavailable` |
| `POST` | `/v1/auth/phone/send-code` | `{"phone":"13800138000"}`。演示且没配短信时，响应带 `demoCode` |
| `POST` | `/v1/auth/login` | 手机号带 `smsCode`（演示模式也可带 `demoCode`，值为 `SKY-LOCAL`）。微信带 `authorizationCode`。Google 带 `idToken`，或 `authorizationCode` + `redirectUri` + `clientId` |
| `POST` | `/v1/auth/bind` | `Authorization: Bearer`。身份属于别人时合并进更早的账号 |
| `GET` | `/v1/auth/identities` | 当前账号的身份 |
| `DELETE` | `/v1/auth/identities` | body 带 `type` 和 `providerSubject`。最后一种不能删 |
| `POST` | `/v1/auth/logout` | 204，作废当前 token |
| `GET` | `/v1/auth/wechat/callback` | 302 到 `skywanderer://auth/wechat` |
| `GET` | `/v1/auth/google/callback` | 302 到 `skywanderer://auth/google` |

手机号收成 E.164。`13800138000` 和 `+86 138-0013-8000` 是同一个身份 `+8613800138000`。

成功的登录 / 绑定响应包含 `user`、`session`、`created`、`merged`、`identities`。`user.mergedFromUserIds` 始终是数组。`retiredAt` 和 `mergedIntoUserId` 没有时为 `null`。错误是 `{"error":{"code","message"}}`。

Postgres 里的会话 token 只存 SHA-256。合并规则的单测在 `codes/user`。
