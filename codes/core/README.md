# core

HTTP 网关。`cmd/api` 监听 `PORT`（默认 `8787`），供本地和 Vercel 的 Go 服务使用。

- `GET /health`
- `codes/user` 的登录路由挂在这里
- `sport` 是运动、轨迹、路线的扩展点。现在 `sport.Routes()` 是空的

在仓库根：

```bash
go test ./codes/user/ ./codes/core/...
AUTH_DEMO=1 PORT=8787 go run ./codes/core/cmd/api
```

部署说明见 [docs/architecture-backend.md](../../docs/architecture-backend.md)。
