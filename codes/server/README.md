# 账号身份服务

一个用户可以绑定手机号、微信、Google。同一种身份再次登录会回到原来的用户。把已经属于别人的身份绑到当前账号上时，合并进**更早创建**的那个账号，后创建的账号标记为停用。

生产数据在 Sky 自己的 Postgres 里。迁移在 `migrations/`。`AUTH_DEMO=1` 且没有 `DATABASE_URL` 时，才把数据写到 JSON 文件，供本机演示。

手机号要先 `POST /v1/auth/phone/send-code`，再用短信里的验证码登录。短信通道由 `SMS_PROVIDER` 选择（`http` 或 `aliyun`）。没配密钥时返回 `sms_not_configured`，不会假装发出去。只有 `AUTH_DEMO=1` 才接受演示码 `SKY-LOCAL`。

微信登录要带授权码。服务用 `WECHAT_APP_ID` / `WECHAT_APP_SECRET` 向微信换 openid。生产模式不采用客户端自己填的 openid。

Google 登录要带 ID token，或带授权码（服务再用 `GOOGLE_CLIENT_SECRET` 换成 ID token 并验签）。身份用 token 里的 `sub`。`aud` 必须落在 `GOOGLE_CLIENT_IDS` 里。

部署到和 Timia 同一台机器、但互不修改的步骤见 [docs/deploy-sky.md](../../docs/deploy-sky.md)。API 主机名是 `api.sky-wanderer.online`。

## 合并规则

1. 比较两边的 `createdAt`，更早的是主账号。
2. `createdAt` 相同则取 `id` 字符串更小的那个。
3. 把失败者的身份、会话，以及 `owned_records` 里的账号数据改挂到主账号。
4. 主账号已有的昵称和邮箱保留；空着的字段用失败者的值补上。
5. 失败者写入 `retiredAt` 和 `mergedIntoUserId`，不物理删除。
6. 发起绑定的这张会话改指向主账号。之后用任一身份登录都回到主账号。
7. 解绑后至少要留一种身份。

iPhone 在没配 API 地址或打开 `SKY_AUTH_DEMO` 时，本机目录（`codes/ios/Shared/AccountIdentity.swift`）使用同一套规则。配了 `https://api.sky-wanderer.online` 之后，校验在这台服务上完成，手机只保存服务端发的 session，并写入 Keychain。

## 运行

```bash
cd codes/server
npm test
AUTH_DEMO=1 PORT=8787 npm start
```

生产形态要有 `DATABASE_URL`，并把 `AUTH_DEMO` 设为 `0`。示例变量在 `env.sample`。

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/health` | 数据库可用时 `{"ok":true}` |
| `POST` | `/v1/auth/phone/send-code` | body：`{"phone":"13800138000"}`。演示模式且没配短信时，响应里带 `demoCode` |
| `POST` | `/v1/auth/login` | 手机号带 `smsCode`（演示模式仍可带 `demoCode`）。微信带 `authorizationCode`。Google 带 `idToken`，或 `authorizationCode` + `redirectUri` + `clientId` |
| `POST` | `/v1/auth/bind` | `Authorization: Bearer`。身份属于别人时按上面的规则合并 |
| `GET` | `/v1/auth/identities` | 当前账号的身份 |
| `DELETE` | `/v1/auth/identities` | body 里带 `type` 和 `providerSubject`。最后一种不能删 |
| `POST` | `/v1/auth/logout` | 作废当前 token |
| `GET` | `/v1/auth/wechat/callback` | 转到 `skywanderer://auth/wechat` |
| `GET` | `/v1/auth/google/callback` | 转到 `skywanderer://auth/google` |

手机号会收成 E.164。`13800138000` 和 `+86 138-0013-8000` 是同一个身份 `+8613800138000`。

会话 token 由服务端生成。Postgres 里只存它的 SHA-256。
