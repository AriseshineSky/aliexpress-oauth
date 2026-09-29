# AGENTS.md — Everymarket OAuth (aliexpress-oauth)

Rails 8.1 / Ruby 4.0 / SQLite (fallback) + Upstash Redis (primary) 的 OAuth 回调中心。
同时服务 **AliExpress IOP** 与 **Mercado Livre (MLB)** 两个平台的授权回调与 Token 存储。

## 架构要点

- 凭证存 Redis Hash（每个平台一个 key）：
  - AliExpress:`aliexpress:oauth:apps`（field=app_key）
  - Mercado Livre:`mercadolivre:oauth:apps`（field=Client ID）
- Token 存 Redis String，带 TTL（`expires_in + 缓冲`），按平台/App 隔离：
  - `aliexpress:oauth:token:{app_key}`（primary 另写兼容旧 key `aliexpress:oauth:token`）
  - `mercadolivre:oauth:token:{app_key}`
- SQLite 仅作 AliExpress 本地回退（`AliExpressToken`），ML 只走 Redis。
- 多 App 共用同一 Callback；`state` 内嵌 `app_key`（AliExpress：`v1.{key}.{nonce}`；ML：`ml.v1.{key}.{nonce}`），callback 按 state 取 Secret。
- 控制台 `POST /apps` / `/ml/apps` 写入 Redis，无需改 Render env 或重新 Deploy。

## 目录组织

- `Aliexpress.*` → `app/services/aliexpress/`（`AppRegistry` / `TokenStore` / `Oauth` / `IopClient` / `ProductClient`）
- `MercadoLivre.*` → `app/services/mercado_livre/`（`AppRegistry` / `TokenStore` / `Oauth` / `Client`）
- 控制器：`OauthController`（AliExpress）、`MercadoLivreController`（ML）、`HomeController`（控制台首页，渲染两个分区 partial：`views/home/_aliexpress.html.erb` / `_mercadolivre.html.erb`）
- 平台配置：`config/initializers/aliexpress.rb`、`config/initializers/mercadolivre.rb`（env + Redis 合并，env 同 key 时优先）

## 惯例

- 新增平台：完全镜像现有双平台模式（initializer 挂全局模块 → services 三层 → 控制器 → 首页 partial → BasicAuth 白名单 → .env.example → README）。
- Redis 依赖一律先查 `defined?(REDIS) && REDIS.present?`（本地无 REDIS_URL 时优雅降级/返回空）。
- callback 必须是幂等的（code 缓存防浏览器重复提交）；state 校验用 `ActiveSupport::SecurityUtils.secure_compare`。
- 页面文案用中文（对齐现有 UI）；Token/Secret 永不整段输出，用 `mask_secret` helper 打码。
- 所有 `Frozen string literal` 注释 + RuboCop omakase + `bin/rubocop -a` 后再提交。

## 常见坑

- 开发环境首页 `/` 会 404：`config/environments/development.rb` 设了
  `config.action_controller.raise_on_missing_callback_actions = true`，而 `allow_browser ... except: :callback`
  在无 `callback` action 的 `HomeController` 上会抛异常。生产（raise=false）不受影响。
- Render 免费实例的 SQLite 盘是临时的；生产 DB 路径默认 `/tmp`。Token 以 Redis 为准。
- 外部 OAuth 跳转必须带 `allow_other_host: true`。
- ML 的 Redirect URI 必须 HTTPS；本地验证用 `bin/tunnel`（cloudflared）拿到 https 地址。
- 不要把 `config/master.key`、`.env`、真实 Secret 提交。

## 常用命令

- 本地开发：`bin/dev`、`bin/tunnel`（https 隧道）
- 检查：`bin/rubocop`、`bin/rails zeitwerk:check`、`bin/rails routes`
- 部署：推 main → Render 自动 deploy（`render.yaml`）；健康检查 `GET /up`