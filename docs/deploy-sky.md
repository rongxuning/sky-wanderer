# 部署 Sky 账号服务

这份说明只描述目标机器上的骨架。本仓库的改动**不会**登录 `124.222.228.215`，也不会改 Timia 的 compose、Nginx 或环境变量。

Sky 和 Timia 用同一台机器，但是分开跑：

- 目录：`/opt/sky-wanderer`（放这份仓库的检出）
- Compose 项目名：`sky-wanderer`
- Postgres：容器 `sky-wanderer-postgres`，卷 `sky_wanderer_postgres`。不要连 Timia 的库。
- API 只绑在本机 `127.0.0.1:8788`（可用 `SKY_BIND_PORT` 改）。先确认这个端口没有被 Timia 占用。
- Nginx：单独的 `server_name api.sky-wanderer.online`，不要写进 Timia 的站点文件。

## DNS 和证书

先加一条 A 记录：

| 主机 | 类型 | 值 |
| --- | --- | --- |
| `api.sky-wanderer.online` | A | `124.222.228.215` |

证书等 DNS 生效后再签，只签这个名字，例如：

```bash
certbot certonly --webroot -w /var/www/sky-wanderer -d api.sky-wanderer.online
```

签好以后，在**自己的**站点文件里加 443，证书路径用 `/etc/letsencrypt/live/api.sky-wanderer.online/`。不要让 certbot 改写 Timia 的站点。在此之前，`deploy/nginx/api.sky-wanderer.online.conf` 只监听 80。

## 启动

在服务器上检出仓库到 `/opt/sky-wanderer` 之后：

```bash
cd /opt/sky-wanderer
cp deploy/env.sample deploy/.env
# 编辑 deploy/.env，至少换掉 POSTGRES_PASSWORD。不要把填好的文件提交进仓库。
docker compose --env-file deploy/.env -f deploy/docker-compose.prod.yml up -d --build
```

把 `deploy/nginx/api.sky-wanderer.online.conf` 装成单独的 Nginx 站点并 reload。本机检查：

```bash
curl -sS http://127.0.0.1:8788/health
```

应返回 `{"ok":true}`。数据库没起来时是 503。

## 要人填的密钥

仓库里没有短信、微信、Google 的密钥。没填时接口会返回明确错误，不会假装成功。

| 变量 | 作用 |
| --- | --- |
| `POSTGRES_PASSWORD` | Sky 自己的 Postgres。Compose 会把它写进 `DATABASE_URL`。请用字母和数字，避免把 URL 弄坏。 |
| `AUTH_DEMO` | 生产设为 `0`。设为 `1` 时手机号接受演示码 `SKY-LOCAL`，微信和 Google 在没有授权码时接受客户端传来的 openid / `sub`。 |
| `AUTH_CODE_PEPPER` | 短信验证码哈希的额外盐。建议填一串随机字符。不填也能启动，只是哈希不带盐。 |
| `SMS_PROVIDER` | `http` 或 `aliyun`。空着时，非演示模式发验证码会返回 `sms_not_configured`。 |
| `SMS_HTTP_URL` / `SMS_HTTP_TOKEN` | `http` 适配器。服务会 POST JSON：`{"phone","code","signName","templateCode"}`。 |
| `ALIYUN_SMS_ACCESS_KEY_ID` / `ALIYUN_SMS_ACCESS_KEY_SECRET` / `ALIYUN_SMS_SIGN_NAME` / `ALIYUN_SMS_TEMPLATE_CODE` | 阿里云短信 SendSms。模板参数是 `{"code":"123456"}`。 |
| `WECHAT_APP_ID` / `WECHAT_APP_SECRET` | 服务端用授权码换 openid。生产模式不信任客户端自己报的 openid。微信后台回调地址填 `https://api.sky-wanderer.online/v1/auth/wechat/callback`。 |
| `GOOGLE_CLIENT_IDS` | 允许的 ID token `aud`，逗号分隔。 |
| `GOOGLE_CLIENT_SECRET` | Web 客户端的密钥，用来用授权码换 ID token。 |
| `GOOGLE_REDIRECT_URIS` | 允许的回调。默认 `https://api.sky-wanderer.online/v1/auth/google/callback`。这个地址也要写在 Google Cloud 的 Web 客户端里。 |

iPhone 工程默认请求 `https://api.sky-wanderer.online`，配置在 `codes/ios/Config/Sky.xcconfig`。微信 AppID、Google 客户端 ID 是公开标识，填在同一份 xcconfig 的 `SKY_WECHAT_APP_ID` 和 `SKY_GOOGLE_CLIENT_ID`。密钥只放服务器。

本机演示：把 `SKY_API_BASE_URL` 留空，或把 `SKY_AUTH_DEMO` 设为 `1`。这时不访问服务器，手机号仍显示 `SKY-LOCAL`。

在没有 Postgres 的机器上试进程：`AUTH_DEMO=1 npm start`（在 `codes/server`）。不设 `AUTH_DEMO` 又不设 `DATABASE_URL` 时，进程会直接退出并说明原因。
