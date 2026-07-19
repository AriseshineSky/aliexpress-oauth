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

  # POST /apps — register AppKey/Secret in Redis (no Render env redeploy)
  def create_app
    unless Aliexpress::AppRegistry.enabled? && redis_connected?
      redirect_to root_path, alert: "Redis 未连接，无法保存 App 凭证。"
      return
    end

    Aliexpress::AppRegistry.upsert!(
      app_key: params.require(:app_key),
      app_secret: params.require(:app_secret),
      label: params[:label]
    )
    redirect_to root_path, notice: "已保存 App #{params[:app_key]} 到 Redis，可直接点「开始授权」。"
  rescue ActionController::ParameterMissing => e
    redirect_to root_path, alert: "缺少字段：#{e.param}"
  rescue ArgumentError => e
    redirect_to root_path, alert: e.message
  rescue Redis::BaseError => e
    redirect_to root_path, alert: "Redis 写入失败：#{e.message}"
  end

  # DELETE /apps/:app_key — remove Redis-registered app (env apps cannot be deleted here)
  def destroy_app
    app_key = params[:app_key].to_s.strip
    app = Aliexpress.find_app(app_key)

    unless app
      redirect_to root_path, alert: "未知 app_key=#{app_key.inspect}"
      return
    end

    unless app.redis?
      redirect_to root_path, alert: "App #{app_key} 来自环境变量，请到 Render 删除对应 env。"
      return
    end

    Aliexpress::AppRegistry.delete!(app_key)
    redirect_to root_path, notice: "已从 Redis 删除 App #{app_key}（Token 未自动清除）。"
  rescue ArgumentError => e
    redirect_to root_path, alert: e.message
  rescue Redis::BaseError => e
    redirect_to root_path, alert: "Redis 删除失败：#{e.message}"
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
