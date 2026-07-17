# frozen_string_literal: true

class HomeController < ApplicationController
  def index
    @configured = Aliexpress.configured?
    @callback_url = Aliexpress.config.callback_url
    @apps = Aliexpress.apps
    @tokens_by_app = @apps.to_h { |app| [ app.app_key, AliExpressToken.current_token(app_key: app.app_key) ] }
    @redis_ok = redis_connected?
    @basic_auth_on = ENV["BASIC_AUTH_USER"].present? && ENV["BASIC_AUTH_PASSWORD"].present?
  end

  # POST /oauth/refresh?app_key=539578 — force refresh_token exchange
  def refresh_token
    app_key = params[:app_key].presence || Aliexpress.primary_app&.app_key
    app = Aliexpress.find_app(app_key)
    unless app
      redirect_to root_path, alert: "未知 app_key=#{app_key.inspect}"
      return
    end

    token = AliExpressToken.current_token(app_key: app.app_key)
    if token.nil? || token.refresh_token.blank?
      redirect_to root_path, alert: "App #{app.app_key} 没有可用的 refresh_token，请先完成授权。"
      return
    end

    if token.respond_to?(:refresh_expired?) && token.refresh_expired?
      redirect_to root_path, alert: "App #{app.app_key} 的 refresh_token 已过期，请重新授权。"
      return
    end

    Aliexpress::Oauth.new(app: app).refresh!(token.refresh_token)
    redirect_to root_path, notice: "App #{app.app_key} Token 已刷新并写入 Redis。"
  rescue Aliexpress::Oauth::Error, Aliexpress::IopClient::Error => e
    redirect_to root_path, alert: "刷新失败：#{e.message}"
  end

  private

  def redis_connected?
    return false unless Aliexpress::TokenStore.enabled?

    REDIS.ping == "PONG"
  rescue StandardError
    false
  end
end
