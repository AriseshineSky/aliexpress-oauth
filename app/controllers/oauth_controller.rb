# frozen_string_literal: true

class OauthController < ApplicationController
  # AliExpress redirects here from an external origin (GET with ?code=)
  skip_forgery_protection only: :callback

  # GET /oauth/authorize — redirect browser to AliExpress login / consent
  def authorize
    unless Aliexpress.configured?
      redirect_to root_path, alert: "请先在 .env 中配置 ALIEXPRESS_APP_KEY 和 ALIEXPRESS_APP_SECRET"
      return
    end

    state = SecureRandom.hex(16)
    session[:oauth_state] = state
    redirect_to Aliexpress::Oauth.new.authorization_url(state: state), allow_other_host: true
  end

  # GET /callback (and /oauth/callback) — App Console Callback URL
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
      redirect_to oauth_success_path(token_id: token_id)
      return
    end

    expected = session[:oauth_state].to_s
    incoming = params[:state].to_s
    if expected.present? && incoming.present? && !ActiveSupport::SecurityUtils.secure_compare(expected, incoming)
      @message = "state 校验失败，请只点击一次「开始授权」，不要连续点两次。"
      render :failure, status: :unprocessable_entity
      return
    end

    token = Aliexpress::Oauth.new.exchange_code!(params[:code])
    session.delete(:oauth_state)
    Aliexpress::TokenStore.cache_code_token_id!(params[:code], token.id)
    redirect_to oauth_success_path(token_id: token.id)
  rescue Aliexpress::Oauth::Error, Aliexpress::IopClient::Error => e
    @message = e.message
    @details = e.respond_to?(:body) ? e.body : nil
    render :failure, status: :unprocessable_entity
  end

  def success
    # Prefer Redis — token_id=redis means SQLite was skipped on this host.
    @token = AliExpressToken.current_token
  end

  def failure
    @message ||= "Authorization failed"
  end
end
