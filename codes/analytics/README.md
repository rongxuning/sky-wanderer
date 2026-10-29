# analytics

数据分析和 AI 对接放在这里。

- 调用方是 `codes/core`，在进程内部使用，不单独做一套对 iOS 的 HTTP 登录。
- 账号、会话、短信和 OAuth 留在 `codes/user`。
- 运动记录、轨迹以后从 `codes/core/sport` 进来，分析读那些结果。

本阶段只占这个目录，没有实现，也没有依赖。
