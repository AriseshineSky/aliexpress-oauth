# AliExpress OAuth (Rails 8) — EverymarketSyncTool

Rails 8 应用：实现速卖通开放平台 **OAuth 2.0 Callback URL**，用授权码换取 `access_token`，Token 写入 **Upstash Redis**（带 EXPIRE）并同步 SQLite。

**支持多个开发者 AppKey 共用同一个 Callback**；token 按 AppKey 分 key 存储，互不覆盖。

## App Console 填写

| 字段 | 值 |
|------|-----|
| App Name | 各账号自己的 App |
| App Category | Drop Shipping |
| **Callback URL** | **`https://aliexpress-oauth.onrender.com/callback`**（两个账号填一样） |

路径必须是 `/callback`。

## 多 AppKey 如何区分 Token

| 项目 | 说明 |
|------|------|
| Callback | 两个 App Console 都填同一个 URL |
| 授权入口 | `/oauth/authorize?app_key=539578`（首页按 App 各有按钮） |
| state | 编码 `v1.{app_key}.{nonce}`，callback 据此选 Secret |
| Redis | `aliexpress:oauth:token:{app_key}` |
| 兼容 | primary App 同时写旧 key `aliexpress:oauth:token`（给旧 worker） |

`aliexpress-ds` worker 默认读 `aliexpress:oauth:token:{APP_KEY}`，与此一致。

## Render 环境变量

```
ALIEXPRESS_CALLBACK_URL=https://aliexpress-oauth.onrender.com/callback
REDIS_URL=rediss://default:...@....upstash.io:6379
SECRET_KEY_BASE=（Generate）
BASIC_AUTH_USER=admin
BASIC_AUTH_PASSWORD=强密码

# Primary（第一账号）
ALIEXPRESS_APP_KEY=539674
ALIEXPRESS_APP_SECRET=...
ALIEXPRESS_APP_LABEL=primary

# 第二账号
ALIEXPRESS_APP_KEY_2=539578
ALIEXPRESS_APP_SECRET_2=...
ALIEXPRESS_APP_LABEL_2=vps2

ALIEXPRESS_API_BASE=https://api-sg.aliexpress.com/rest
ALIEXPRESS_AUTHORIZE_URL=https://api-sg.aliexpress.com/oauth/authorize
ALIEXPRESS_TOKEN_PATH=/auth/token/create
```

也可改用 JSON（与上面合并）：

```
ALIEXPRESS_APPS_JSON=[{"app_key":"539578","app_secret":"...","label":"vps2"}]
```

## 怎么用

1. 两个 App Console 的 Callback 都设为  
   `https://aliexpress-oauth.onrender.com/callback`
2. Render 配好 `APP_KEY` + `APP_KEY_2` 等，**手动 Deploy** 拉最新代码
3. 打开 https://aliexpress-oauth.onrender.com/ （Basic Auth）
4. 每个 App 点各自的 **开始授权** → 用对应开发者/买家账号登录同意
5. 成功后 Redis 出现：
   - `aliexpress:oauth:token:539674`（及旧 key）
   - `aliexpress:oauth:token:539578`
6. 各 VPS 的 `aliexpress-ds` `.env` 填对应 `ALIEXPRESS_APP_KEY` / `SECRET` + 同一 `REDIS_URL`

直接打开：

```
https://aliexpress-oauth.onrender.com/oauth/authorize?app_key=539578
```

> 免费 Web Service 无流量会休眠，首次回调可能要等约 30 秒唤醒。

## Callback 流程

```
首页点「开始授权」(带 app_key)
  → /oauth/authorize?app_key=…
  → 速卖通授权页（state 含 app_key）
  → GET /callback?code=…&state=v1.{app_key}.{nonce}
  → 用该 App 的 Secret 调 /auth/token/create
  → 写入 Redis key aliexpress:oauth:token:{app_key}
  → /oauth/success?app_key=…
```

## 路由

| Method | Path | 说明 |
|--------|------|------|
| GET | `/` | 多 App 控制台 |
| GET | `/oauth/authorize?app_key=` | 跳转速卖通授权 |
| GET | **`/callback`** | **共用 Callback** |
| POST | `/oauth/refresh?app_key=` | 强制刷新 |
| GET | `/oauth/success` | 授权成功 |
| GET | `/up` | 健康检查 |

## 本地开发

```bash
cd aliexpress-oauth
cp .env.example .env
# 填入 App Key/Secret；可加 APP_KEY_2
bin/setup
bin/dev
```

## 核心代码

- `OauthController#callback` — 按 state 里的 app_key 换 token
- `Aliexpress.apps` — 从 env 加载多套凭证
- `Aliexpress::TokenStore` — `aliexpress:oauth:token:{app_key}`
- `Aliexpress::Oauth` / `IopClient` — 按 App 签名
