# frozen_string_literal: true

class MercadoLivreController < ApplicationController
  # Mercado Livre redirects here from an external origin (GET with ?code=)
  skip_forgery_protection only: :callback

  # GET /ml/authorize?app_key=… — redirect browser to Mercado Livre login / consent
  def authorize
    unless MercadoLivre.configured?
      redirect_to root_path, alert: "请先在首页把 Mercado Livre 的 Client ID / Secret 保存到 Redis（或配置环境变量）"
      return
    end

    app = resolve_app_param
    unless app
      redirect_to root_path, alert: "未知 app_key=#{params[:app_key].inspect}"
      return
    end

    state = MercadoLivre::Oauth.build_state(app.app_key)
    session[:ml_oauth_state] = state
    session[:ml_oauth_app_key] = app.app_key

    verifier = MercadoLivre::Pkce.generate_verifier
    unless MercadoLivre::PkceStore.set!(state, verifier)
      redirect_to root_path, alert: "Redis 未连接，无法保存 PKCE code_verifier，请稍后再试。"
      return
    end

    redirect_to MercadoLivre::Oauth.new(app: app).authorization_url(
      state: state,
      code_challenge: MercadoLivre::Pkce.challenge_for(verifier)
    ), allow_other_host: true
  end

  # GET /ml/share_url?app_key=… — build a forwardable auth link (production HTTPS
  # Redirect URI). Useful when the local network is geo-blocked by ML CloudFront:
  # send the link to someone on a BR/LATAM network, their browser redirects to the
  # production /ml/callback and the token lands in the shared Redis.
  def share_url
    app = resolve_app_param
    unless app
      redirect_to root_path, alert: "未知 app_key=#{params[:app_key].inspect}"
      return
    end

    state = MercadoLivre::Oauth.build_state(app.app_key)
    verifier = MercadoLivre::Pkce.generate_verifier
    unless MercadoLivre::PkceStore.set!(state, verifier)
      redirect_to root_path, alert: "Redis 未连接，无法保存 PKCE code_verifier；请先配置共享 Redis。"
      return
    end

    @app = app
    @authorize_url = MercadoLivre::Oauth.new(app: app).authorization_url(
      state: state,
      redirect_uri: MercadoLivre.config.share_callback_url,
      code_challenge: MercadoLivre::Pkce.challenge_for(verifier)
    )
    @share_callback_url = MercadoLivre.config.share_callback_url
  end

  # GET /ml/callback — shared Redirect URI for every ML app (read-only scope)
  def callback
    if params[:error].present?
      @message = params[:error_description].presence || params[:error]
      render :failure, status: :unprocessable_entity
      return
    end

    if params[:code].blank?
      # Bare /ml/callback (bookmark, copy-paste) — not a real OAuth return.
      Rails.logger.info(
        "[mercadolivre/callback] missing code path=#{request.fullpath} referer=#{request.referer.inspect} ua=#{request.user_agent}"
      )
      redirect_to root_path,
                  alert: "不要直接打开 Callback 地址。请在首页点对应 App 的「开始授权」，在 Mercado Livre 同意后再自动跳回。"
      return
    end

    # Idempotent: avoid exchanging the same code twice (browser reload / double hit)
    if (token_id = MercadoLivre::TokenStore.cached_token_id_for_code(params[:code]))
      app_key = session[:ml_oauth_app_key].presence || MercadoLivre::Oauth.parse_state(params[:state])[:app_key]
      redirect_to ml_success_path(token_id: token_id, app_key: app_key)
      return
    end

    parsed = MercadoLivre::Oauth.parse_state(params[:state])
    expected = session[:ml_oauth_state].to_s
    incoming = params[:state].to_s
    if expected.present? && incoming.present? && !ActiveSupport::SecurityUtils.secure_compare(expected, incoming)
      @message = "state 校验失败，请只点击一次「开始授权」，不要连续点两次。"
      render :failure, status: :unprocessable_entity
      return
    end

    app_key = parsed[:app_key].presence || session[:ml_oauth_app_key].presence || MercadoLivre.primary_app&.app_key
    app = MercadoLivre.find_app(app_key)
    unless app
      @message = "无法识别 app_key=#{app_key.inspect}。请先在首页保存该 App 到 Redis，再点「开始授权」。"
      render :failure, status: :unprocessable_entity
      return
    end

    verifier = MercadoLivre::PkceStore.get(params[:state])
    if verifier.blank?
      @message = "PKCE code_verifier 缺失或已过期（需在 30 分钟内完成授权）。请回首页重新点「转发授权」生成新链接，确认发的是新链接而不是旧的。"
      render :failure, status: :unprocessable_entity
      return
    end

    token = MercadoLivre::Oauth.new(app: app).exchange_code!(params[:code], code_verifier: verifier)
    MercadoLivre::PkceStore.delete!(params[:state])
    session.delete(:ml_oauth_state)
    session.delete(:ml_oauth_app_key)
    MercadoLivre::TokenStore.cache_code_token_id!(params[:code], token.id)
    redirect_to ml_success_path(token_id: token.id, app_key: app.app_key)
  rescue MercadoLivre::Oauth::Error, MercadoLivre::Client::Error => e
    @message = e.message
    @details = e.respond_to?(:body) ? e.body : nil
    render :failure, status: :unprocessable_entity
  end

  # GET /ml/success
  def success
    app_key = params[:app_key].presence || MercadoLivre.primary_app&.app_key
    @app_key = app_key
    @token = MercadoLivre::TokenStore.fetch(app_key: app_key) if app_key.present?
  end

  # POST /ml/apps — register Client ID / Secret in Redis (no Render env redeploy)
  def create_app
    unless MercadoLivre::AppRegistry.enabled? && redis_connected?
      redirect_to root_path, alert: "Redis 未连接，无法保存 App 凭证。"
      return
    end

    MercadoLivre::AppRegistry.upsert!(
      app_key: params.require(:app_key),
      app_secret: params.require(:app_secret),
      label: params[:label],
      site: params[:site]
    )
    site_name = MercadoLivre.site_display(params[:site])
    redirect_to root_path, notice: "已保存 Mercado Livre App #{params[:app_key]}（#{site_name}）到 Redis，可直接点「开始授权」。"
  rescue ActionController::ParameterMissing => e
    redirect_to root_path, alert: "缺少字段：#{e.param}"
  rescue ArgumentError => e
    redirect_to root_path, alert: e.message
  rescue Redis::BaseError => e
    redirect_to root_path, alert: "Redis 写入失败：#{e.message}"
  end

  # DELETE /ml/apps/:app_key — remove Redis-registered app (env apps cannot be deleted here)
  def destroy_app
    app_key = params[:app_key].to_s.strip
    app = MercadoLivre.find_app(app_key)

    unless app
      redirect_to root_path, alert: "未知 app_key=#{app_key.inspect}"
      return
    end

    unless app.redis?
      redirect_to root_path, alert: "App #{app_key} 来自环境变量，请到 Render 删除对应 env。"
      return
    end

    MercadoLivre::AppRegistry.delete!(app_key)
    redirect_to root_path, notice: "已从 Redis 删除 App #{app_key}（Token 未自动清除）。"
  rescue ArgumentError => e
    redirect_to root_path, alert: e.message
  rescue Redis::BaseError => e
    redirect_to root_path, alert: "Redis 删除失败：#{e.message}"
  end

  # POST /ml/refresh?app_key=… — force refresh_token exchange
  def refresh
    app_key = params[:app_key].presence || MercadoLivre.primary_app&.app_key
    app = MercadoLivre.find_app(app_key)
    unless app
      redirect_to root_path, alert: "未知 app_key=#{app_key.inspect}"
      return
    end

    token = MercadoLivre::TokenStore.fetch(app_key: app.app_key)
    if token.nil? || token.refresh_token.blank?
      redirect_to root_path, alert: "App #{app.app_key} 没有可用的 refresh_token，请先完成授权。"
      return
    end

    MercadoLivre::Oauth.new(app: app).refresh!(token.refresh_token)
    redirect_to root_path, notice: "App #{app.app_key} Token 已刷新并写入 Redis。"
  rescue MercadoLivre::Oauth::Error, MercadoLivre::Client::Error => e
    redirect_to root_path, alert: "刷新失败：#{e.message}"
  end

  # GET /ml/items/:item_id — read-only item lookup price/stock via official API (no captcha)
  def item
    @item_id = params[:item_id]

    if params[:app_key].present?
      @token = MercadoLivre::TokenStore.fetch(app_key: params[:app_key])
    end
    @token ||= MercadoLivre::TokenStore.fetch(app_key: MercadoLivre.primary_app&.app_key)

    client = MercadoLivre::Client.new
    @raw = client.get("items/#{@item_id}", access_token: @token&.usable? ? @token.access_token : nil)
  rescue MercadoLivre::Client::Error, MercadoLivre::Oauth::Error => e
    @error = e.message
    @details = e.respond_to?(:body) ? e.body : nil
  end

  private

  def resolve_app_param
    key = params[:app_key].presence
    return MercadoLivre.primary_app if key.blank?

    MercadoLivre.find_app(key)
  end

  def redis_connected?
    return false unless MercadoLivre::AppRegistry.enabled?

    REDIS.ping == "PONG"
  rescue StandardError
    false
  end
end
