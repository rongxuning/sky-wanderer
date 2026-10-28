# 账号身份服务

本地可用的账号服务。一个用户可以绑定手机号、微信、Google。同一种身份再次登录会回到原来的用户。把已经属于别人的身份绑到当前账号上时，合并进**更早创建**的那个账号，后创建的账号标记为停用。

这不是生产登录。手机号只认演示验证码 `SKY-LOCAL`，不会发短信。微信和 Google 只核对接过来的 openid / `sub`，不校验真实 token。

## 合并规则

1. 比较两边的 `createdAt`，更早的是主账号。
2. `createdAt` 相同则取 `id` 字符串更小的那个。
3. 把失败者的身份、会话，以及 `records` 里的账号数据改挂到主账号。
4. 主账号已有的昵称和邮箱保留；空着的字段用失败者的值补上。
5. 失败者写入 `retiredAt` 和 `mergedIntoUserId`，不物理删除。
6. 发起绑定的这张会话改指向主账号。之后用任一身份登录都回到主账号。
7. 解绑后至少要留一种身份。

iPhone 本地目录（`codes/ios/Shared/AccountIdentity.swift`）使用同一套规则，另外会在主账号没有密码时收下失败者的密码哈希。锻炼记录仍是整机一份，不按账号拆。

## 运行

```bash
cd codes/server
npm test
DATA_FILE=data/auth-store.json PORT=8787 npm start
```

## 试一次合并

先登录微信（更早的账号），再登录手机号，然后用手机号的 token 去绑定那个微信。响应里的 `user.id` 是更早的微信账号，`merged` 为 `true`。

```bash
EARLY=$(curl -s -X POST localhost:8787/v1/auth/login \
  -H 'content-type: application/json' \
  -d '{"type":"wechat","providerSubject":"openid-demo","displayName":"早的账号"}')

LATE=$(curl -s -X POST localhost:8787/v1/auth/login \
  -H 'content-type: application/json' \
  -d '{"type":"phone","providerSubject":"13800138000","demoCode":"SKY-LOCAL","displayName":"晚的账号"}')

TOKEN=$(node -e 'console.log(JSON.parse(process.argv[1]).session.token)' "$LATE")

curl -s -X POST localhost:8787/v1/auth/bind \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"type":"wechat","providerSubject":"openid-demo"}'
```

再用 `openid-demo` 或 `+8613800138000` 登录，都是同一个用户。

只剩一种身份时：

```bash
curl -s -X DELETE localhost:8787/v1/auth/identities \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"type":"phone","providerSubject":"+8613800138000"}'

curl -s -o /dev/null -w '%{http_code}\n' -X DELETE localhost:8787/v1/auth/identities \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"type":"wechat","providerSubject":"openid-demo"}'
```

第二次返回 `409`，`error.code` 是 `last_identity`。

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `POST` | `/v1/auth/login` | 按身份登录；没有则注册。手机号要带 `demoCode: SKY-LOCAL` |
| `POST` | `/v1/auth/bind` | `Authorization: Bearer`。身份属于别人时按上面的规则合并 |
| `GET` | `/v1/auth/identities` | 当前账号的身份 |
| `DELETE` | `/v1/auth/identities` | body 里带 `type` 和 `providerSubject`。最后一种不能删 |
| `POST` | `/v1/auth/logout` | 作废当前 token |

手机号会收成 E.164。`13800138000` 和 `+86 138-0013-8000` 是同一个身份 `+8613800138000`。

iPhone 上对应 `PhoneAppState` 的 `signInPhone(phone:demoCode:)`、`signInWeChat(openId:)`、`signInGoogle(subject:)`、`bindPhone`、`bindWeChat`、`bindGoogle`、`unbindIdentity`。登录页仍是原来的账号密码，这套身份接口留给后续的登录界面。数据写在原来的 `phone.json` 里。
