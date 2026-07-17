# frozen_string_literal: true

class OauthController < ApplicationController
  # AliExpress redirects here from an external origin (GET with ?code=)
  skip_forgery_protection only: :callback

  # GET /oauth/authorize?app_key=539578 — redirect browser to AliExpress login / consent
  def authorize
    unless Aliexpress.configured?
      redirect_to root_path, alert: "请先配置 ALIEXPRESS_APP_KEY / SECRET（及可选的 _2 / APPS_JSON）"
      return
    end

    app = resolve_app_param
    unless app
      redirect_to root_path, alert: "未知 app_key=#{params[:app_key].inspect}"
      return
    end

    state = Aliexpress::Oauth.build_state(app.app_key)
    session[:oauth_state] = state
    session[:oauth_app_key] = app.app_key
    redirect_to Aliexpress::Oauth.new(app: app).authorization_url(state: state), allow_other_host: true
  end

  # GET /callback (and /oauth/callback) — shared Callback URL for all AppKeys
  def callback
    if params[:error].present?
      @message = params[:error_description].presence || params[:error]
      render :failure, status: :unprocessable_entity
      return
    end

    if params[:code].blank?
      @message = "回调缺少 code 参数。请确认 App Console 的 Callback URL 指向本路径。"
      render :failure, status: :bad_request
      return
    end

    # Idempotent: avoid exchanging the same code twice (browser reload / double hit)
    if (token_id = Aliexpress::TokenStore.cached_token_id_for_code(params[:code]))
      app_key = session[:oauth_app_key].presence || Aliexpress::Oauth.parse_state(params[:state])[:app_key]
      redirect_to oauth_success_path(token_id: token_id, app_key: app_key)
      return
    end

    parsed = Aliexpress::Oauth.parse_state(params[:state])
    expected = session[:oauth_state].to_s
    incoming = params[:state].to_s
    if expected.present? && incoming.present? && !ActiveSupport::SecurityUtils.secure_compare(expected, incoming)
      @message = "state 校验失败，请只点击一次「开始授权」，不要连续点两次。"
      render :failure, status: :unprocessable_entity
      return
    end

    app_key = parsed[:app_key].presence || session[:oauth_app_key].presence || Aliexpress.primary_app&.app_key
    app = Aliexpress.find_app(app_key)
    unless app
      @message = "无法识别 app_key=#{app_key.inspect}。请从首页带 app_key 重新授权，或在 Render 配置该 App。"
      render :failure, status: :unprocessable_entity
      return
    end

    token = Aliexpress::Oauth.new(app: app).exchange_code!(params[:code])
    session.delete(:oauth_state)
    session.delete(:oauth_app_key)
    Aliexpress::TokenStore.cache_code_token_id!(params[:code], token.id)
    redirect_to oauth_success_path(token_id: token.id, app_key: app.app_key)
  rescue Aliexpress::Oauth::Error, Aliexpress::IopClient::Error => e
    @message = e.message
    @details = e.respond_to?(:body) ? e.body : nil
    render :failure, status: :unprocessable_entity
  end

  def success
    app_key = params[:app_key].presence || Aliexpress.primary_app&.app_key
    @app_key = app_key
    @token = AliExpressToken.current_token(app_key: app_key)
  end

  def failure
    @message ||= "Authorization failed"
  end

  private

  def resolve_app_param
    key = params[:app_key].presence
    return Aliexpress.primary_app if key.blank?

    Aliexpress.find_app(key)
  end
end
