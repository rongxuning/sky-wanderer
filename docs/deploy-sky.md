# 部署 Sky 账号服务

临时目标是 **Vercel + Neon**。同机目录 `/opt/sky-wanderer`、本机 Postgres 和 `api.sky-wanderer.online` 的 Nginx **先不动、也不在这台机器上发布**。本仓库的改动不会登录 `124.222.228.215`，也不会改 Timia 的 compose、Nginx 或环境变量。

`deploy/docker-compose.prod.yml` 不再构建服务。`deploy/nginx/api.sky-wanderer.online.conf` 保持原样，不要装到那台机器上。

## 三个目录

| 目录 | 职责 |
| --- | --- |
| `codes/core` | HTTP 网关。`GET /health`，挂载账号路由，监听 `PORT`。运动、轨迹以后加在 `codes/core/sport`。 |
| `codes/user` | 手机号、微信、Google 登录和账号合并。Postgres 迁移在 `codes/user/migrations`。 |
| `codes/analytics` | 数据分析和 AI。由 core 以后在进程内调用。本阶段只有说明，没有实现。 |

模块根在仓库根的 `go.mod`（Vercel 的 Go preset 从这里读版本）。Preset 找入口时不看 `buildCommand`，只认仓库根的 `main.go`、`cmd/api/main.go`、`cmd/server/main.go` 之一。根上的 `cmd/api/main.go` 是薄封装，只调用 `gateway.ListenAndServe()`。服务实现仍在 `codes/core`，本地继续 `go run ./codes/core/cmd/api`。找到入口之后，`vercel.json` 的 `buildCommand` 把 `./cmd/api` 编到 `$VERCEL_OUTPUT_FILE`（本地没有这个变量时落到被 gitignore 的 `./server`）。

## Neon

在 Neon 建好库之后，把连接串放进环境变量，不要提交：

| 变量 | 填什么 |
| --- | --- |
| `DATABASE_URL` | **Pooled** URL。主机名里有 `-pooler`。运行中的查询走这条。 |
| `DATABASE_URL_UNPOOLED` | **Direct** URL。启动时做迁移。不填则迁移也用 `DATABASE_URL`。 |

两条都要带 `sslmode=require`。示例在 `codes/env.sample` 和 `deploy/env.sample`。

进程对 Neon pooler 使用简单查询协议，避免事务模式下的 prepared statement 被拆掉。

## Vercel

1. 新建项目，Root Directory 用仓库根（不要改成 `codes/server`，那个目录已经删除）。
2. Framework Preset 选 Go，Root Directory 保持仓库根。Preset 先确认根上有 `go.mod` 和 `cmd/api/main.go`（另外两个合法路径是 `main.go`、`cmd/server/main.go`），通过之后才跑 `vercel.json` 里的 `buildCommand`：`go build -o "$VERCEL_OUTPUT_FILE" ./cmd/api`。编出来的二进制监听 `PORT`。不要把 Root Directory 改成 `codes/core`，那里没有 `go.mod`。
3. 把 `deploy/env.sample` 里的变量填进项目的 Environment Variables。生产把 `AUTH_DEMO` 设为 `0`。
4. 部署完成后，用项目域名检查：`curl -sS https://<project>.vercel.app/health`，数据库通的时候是 `{"ok":true}`。

iPhone 默认仍请求 `https://api.sky-wanderer.online`（`codes/ios/Config/Sky.xcconfig` 的 `SKY_API_BASE_URL`）。要改打到 Vercel，只改这一行的主机名，继续用 `SKY_URL_SLASH` 拼接，例如：

```
SKY_API_BASE_URL = https:$(SKY_URL_SLASH)$(SKY_URL_SLASH)your-project.vercel.app
```

微信、Google 的回调会跟着变成 `https://<project>.vercel.app/v1/auth/wechat/callback` 和 `.../google/callback`。微信开放平台和 Google Cloud 里的回调白名单要一起改。登录页不用改。

## 本机

没有数据库时：

```bash
AUTH_DEMO=1 PORT=8787 go run ./codes/core/cmd/api
```

这时手机号接受 `SKY-LOCAL`，数据写在 `data/auth-store.json`。不设 `AUTH_DEMO` 又不设 `DATABASE_URL` 时，进程会退出并说明原因。

有 Neon（或别的 Postgres）时，导出 `DATABASE_URL`，把 `AUTH_DEMO` 设为 `0`，再跑同一条命令。测试：

```bash
go test ./codes/user/ ./codes/core/...
```

## 要人填的密钥

仓库里没有短信、微信、Google 的密钥。没填时接口会返回明确错误，不会假装成功。

| 变量 | 作用 |
| --- | --- |
| `DATABASE_URL` | Neon pooled URL。`AUTH_DEMO=1` 且不填时改用本地 JSON。 |
| `DATABASE_URL_UNPOOLED` | Neon direct URL，给迁移用。 |
| `AUTH_DEMO` | 生产设为 `0`。设为 `1` 时手机号接受演示码 `SKY-LOCAL`，微信和 Google 在没有授权码时接受客户端传来的 openid / `sub`。 |
| `AUTH_CODE_PEPPER` | 短信验证码哈希的额外盐。建议填一串随机字符。不填也能启动，只是哈希不带盐。 |
| `SMS_PROVIDER` | `http` 或 `aliyun`。空着时，非演示模式发验证码会返回 `sms_not_configured`。 |
| `SMS_HTTP_URL` / `SMS_HTTP_TOKEN` | `http` 适配器。服务会 POST JSON：`{"phone","code","signName","templateCode"}`。 |
| `ALIYUN_SMS_ACCESS_KEY_ID` / `ALIYUN_SMS_ACCESS_KEY_SECRET` / `ALIYUN_SMS_SIGN_NAME` / `ALIYUN_SMS_TEMPLATE_CODE` | 阿里云短信 SendSms。模板参数是 `{"code":"123456"}`。 |
| `WECHAT_APP_ID` / `WECHAT_APP_SECRET` | 服务端用授权码换 openid。生产模式不信任客户端自己报的 openid。 |
| `GOOGLE_CLIENT_IDS` | 允许的 ID token `aud`，逗号分隔。 |
| `GOOGLE_CLIENT_SECRET` | Web 客户端的密钥，用来用授权码换 ID token。 |
| `GOOGLE_REDIRECT_URIS` | 允许的回调。默认 `https://api.sky-wanderer.online/v1/auth/google/callback`。 |

iPhone 上的微信 AppID、Google 客户端 ID 仍是公开标识，填在 `codes/ios/Config/Sky.xcconfig`。密钥只放 Vercel。

本机演示：把 `SKY_API_BASE_URL` 留空，或把 `SKY_AUTH_DEMO` 设为 `1`。这时不访问服务器，手机号仍显示 `SKY-LOCAL`。
