# AliExpress OAuth (Rails 8) — EverymarketSyncTool

Rails 8 应用：实现速卖通开放平台 **OAuth 2.0 Callback URL**，用授权码换取 `access_token`，Token 写入 **Upstash Redis**（带 EXPIRE）并同步 SQLite。

## App Console 填写

| 字段 | 值 |
|------|-----|
| App Name | `EverymarketSyncTool` |
| App Category | Drop Shipping |
| **Callback URL** | **`https://aliexpress-oauth.onrender.com/callback`** |

路径必须是 `/callback`，与 Console 示例 `https://www.myapp.com/callback` 一致。

## Render 部署（免费 HTTPS）

1. 把本仓库推到 GitHub
2. [Upstash](https://upstash.com/) 免费建一个 Redis，复制 `REDIS_URL`（`rediss://...`）
3. [Render](https://render.com/) → New → Blueprint（选本仓库的 `render.yaml`），或 New Web Service：
   - Name: **`aliexpress-oauth`** → 域名 `https://aliexpress-oauth.onrender.com`
   - Runtime: Docker
4. 在 Render Environment 填入：

```
ALIEXPRESS_APP_KEY=你的AppKey
ALIEXPRESS_APP_SECRET=你的AppSecret
ALIEXPRESS_CALLBACK_URL=https://aliexpress-oauth.onrender.com/callback
REDIS_URL=rediss://default:...@....upstash.io:6379
SECRET_KEY_BASE=（Render 可自动生成）
```

5. 部署完成后，用首页的 **开始授权**，或直接打开：

```
https://aliexpress-oauth.onrender.com/oauth/authorize
```

> 免费 Web Service 无流量会休眠，首次回调可能要等约 30 秒唤醒，内部工具可接受。

## Callback 流程

```
卖家点授权
  → https://api-sg.aliexpress.com/oauth/authorize?...
  → 同意后跳转 GET https://aliexpress-oauth.onrender.com/callback?code=...&state=...
  → 后端 POST /auth/token/create 换取 access_token
  → 写入 Upstash Redis（EXPIRE）+ SQLite
  → 跳转 /oauth/success
```

## 路由

| Method | Path | 说明 |
|--------|------|------|
| GET | `/` | 配置状态与入口 |
| GET | `/oauth/authorize` | 跳转速卖通授权页 |
| GET | **`/callback`** | **App Console Callback URL** |
| GET | `/oauth/callback` | 同上（兼容别名） |
| GET | `/oauth/success` | 授权成功 |
| GET | `/products/:id` | 用 token 调 DS 产品详情 |
| GET | `/up` | Render / 健康检查 |

## 本地开发

```bash
cd aliexpress-oauth
cp .env.example .env
# 填入 App Key / Secret；本地 Callback 用 http://localhost:3000/callback

bin/setup
bin/dev
```

需要 Console 验收 HTTPS 时：

```bash
bin/dev-https   # Cloudflare Quick Tunnel，会写 ALIEXPRESS_CALLBACK_URL
```

本地也可选填 `REDIS_URL`（Upstash）；不填则只写 SQLite。

## 环境变量

| 变量 | 说明 |
|------|------|
| `ALIEXPRESS_APP_KEY` | App Key |
| `ALIEXPRESS_APP_SECRET` | App Secret |
| `ALIEXPRESS_CALLBACK_URL` | 与 Console **完全一致** 的回调地址 |
| `REDIS_URL` | Upstash Redis URL（生产强烈推荐） |
| `ALIEXPRESS_API_BASE` | 默认 `https://api-sg.aliexpress.com/rest` |
| `ALIEXPRESS_AUTHORIZE_URL` | 默认 `https://api-sg.aliexpress.com/oauth/authorize` |
| `ALIEXPRESS_TOKEN_PATH` | 默认 `/auth/token/create` |

## 核心代码

- `OauthController#callback` — 接收 `code`，换 token
- `Aliexpress::Oauth` — 授权 URL、code 换 token、refresh
- `Aliexpress::TokenStore` — Redis SET + EXPIRE
- `Aliexpress::IopClient` — IOP HMAC-SHA256 签名
