# AliExpress OAuth (Rails 8) — EverymarketSyncTool

Rails 8 应用：实现速卖通开放平台 **OAuth 2.0 Callback URL**，用授权码换取 `access_token`，Token 写入 **Upstash Redis**（带 EXPIRE）并同步 SQLite。

**支持多个开发者 AppKey 共用同一个 Callback**；App 凭证与 Token 都按 AppKey 存在 Redis，互不覆盖。

## App Console 填写

| 字段 | 值 |
|------|-----|
| App Name | 各账号自己的 App |
| App Category | Drop Shipping |
| **Callback URL** | **`https://aliexpress-oauth.onrender.com/callback`**（所有账号填一样） |

路径必须是 `/callback`。

## 新账号怎么加（推荐）

1. App Console Callback 填上面的 URL  
2. 打开 https://aliexpress-oauth.onrender.com/ （Basic Auth）  
3. 在 **添加开发者 App** 填入 App Key / Secret / 备注 → **保存到 Redis**  
4. 点该 App 的 **开始授权**  

无需改 Render 环境变量、无需 Redeploy。

| 项目 | Redis key |
|------|-----------|
| App 凭证 | Hash `aliexpress:oauth:apps`（field = app_key） |
| Token | `aliexpress:oauth:token:{app_key}` |
| 兼容 | primary 同时写旧 key `aliexpress:oauth:token` |

`aliexpress-ds` worker 默认读 `aliexpress:oauth:token:{APP_KEY}`，与此一致。

## Render 环境变量

只需这些（App Key/Secret 可全部走 Redis 控制台）：

```
ALIEXPRESS_CALLBACK_URL=https://aliexpress-oauth.onrender.com/callback
REDIS_URL=rediss://default:...@....upstash.io:6379
SECRET_KEY_BASE=（Generate）
BASIC_AUTH_USER=admin
BASIC_AUTH_PASSWORD=强密码

ALIEXPRESS_API_BASE=https://api-sg.aliexpress.com/rest
ALIEXPRESS_AUTHORIZE_URL=https://api-sg.aliexpress.com/oauth/authorize
ALIEXPRESS_TOKEN_PATH=/auth/token/create
```

可选：仍可用环境变量引导首个 App（与 Redis 合并；同 key 时 env 优先）：

```
ALIEXPRESS_APP_KEY=539674
ALIEXPRESS_APP_SECRET=...
ALIEXPRESS_APP_LABEL=primary
```

旧写法 `ALIEXPRESS_APP_KEY_2` / `ALIEXPRESS_APPS_JSON` 仍可用，但新账号请用控制台写入 Redis。

## 怎么用

1. 各 App Console 的 Callback 都设为  
   `https://aliexpress-oauth.onrender.com/callback`
2. 控制台「添加开发者 App」写入 Key/Secret  
3. 每个 App 点 **开始授权** → 用对应开发者/买家账号登录同意  
4. 成功后 Redis 出现 `aliexpress:oauth:token:{app_key}`  
5. 各 VPS 的 `aliexpress-ds` `.env` 填对应 `ALIEXPRESS_APP_KEY` / `SECRET` + 同一 `REDIS_URL`

直接打开：

```
https://aliexpress-oauth.onrender.com/oauth/authorize?app_key=539578
```

> 免费 Web Service 无流量会休眠，首次回调可能要等约 30 秒唤醒。

## Callback 流程

```
控制台保存 AppKey/Secret 到 Redis
  → 首页点「开始授权」(带 app_key)
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
| GET | `/` | 多 App 控制台（含添加表单） |
| POST | `/apps` | 保存 AppKey/Secret 到 Redis |
| DELETE | `/apps/:app_key` | 删除 Redis 中的 App 凭证 |
| GET | `/oauth/authorize?app_key=` | 跳转速卖通授权 |
| GET | **`/callback`** | **共用 Callback** |
| POST | `/oauth/refresh?app_key=` | 强制刷新 |
| GET | `/oauth/success` | 授权成功 |
| GET | `/up` | 健康检查 |

## 本地开发

```bash
cd aliexpress-oauth
cp .env.example .env
# 填 REDIS_URL；App 可在本地首页写入 Redis，或继续用 env
bin/setup
bin/dev
```

## 核心代码

- `OauthController#callback` — 按 state 里的 app_key 换 token
- `Aliexpress::AppRegistry` — Redis Hash 存多套 AppKey/Secret
- `Aliexpress.apps` — env（可选）+ Redis 合并
- `Aliexpress::TokenStore` — `aliexpress:oauth:token:{app_key}`
- `Aliexpress::Oauth` / `IopClient` — 按 App 签名
