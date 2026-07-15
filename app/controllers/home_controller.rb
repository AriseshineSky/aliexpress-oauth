# frozen_string_literal: true

class HomeController < ApplicationController
  def index
    @configured = Aliexpress.configured?
    @callback_url = Aliexpress.config.callback_url
    @token = AliExpressToken.current_token
    @app_key = Aliexpress.config.app_key
    @redis_ok = redis_connected?
    @basic_auth_on = ENV["BASIC_AUTH_USER"].present? && ENV["BASIC_AUTH_PASSWORD"].present?
  end

  # POST /oauth/refresh — force refresh_token exchange
  def refresh_token
    token = AliExpressToken.current_token
    if token.nil? || token.refresh_token.blank?
      redirect_to root_path, alert: "没有可用的 refresh_token，请先完成授权。"
      return
    end

    if token.respond_to?(:refresh_expired?) && token.refresh_expired?
      redirect_to root_path, alert: "refresh_token 已过期，请重新授权。"
      return
    end

    Aliexpress::Oauth.new.refresh!(token.refresh_token)
    redirect_to root_path, notice: "Token 已刷新并写入 Redis。"
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
