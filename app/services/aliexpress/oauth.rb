# frozen_string_literal: true

require "cgi"

module Aliexpress
  # OAuth 2.0 helpers for AliExpress Open Platform.
  class Oauth
    class Error < StandardError; end

    def initialize(app: nil, client: nil)
      @app = app || Aliexpress.primary_app
      raise Error, "No AliExpress app configured" if @app.nil?

      @client = client || IopClient.new(app_key: @app.app_key, app_secret: @app.app_secret)
    end

    def self.for_app_key(app_key)
      app = Aliexpress.find_app(app_key) || raise(Error, "Unknown app_key=#{app_key.inspect} — add it via console (Redis) or env")
      new(app: app)
    end

    # state embeds app_key so /callback can pick the right Secret without session.
    def self.build_state(app_key, nonce: SecureRandom.hex(16))
      "v1.#{app_key}.#{nonce}"
    end

    def self.parse_state(state)
      parts = state.to_s.split(".", 3)
      return {} unless parts.size == 3 && parts[0] == "v1" && parts[1].present?

      { app_key: parts[1], nonce: parts[2] }
    end

    def authorization_url(state: nil, force_auth: true, uuid: nil)
      query = {
        response_type: "code",
        client_id: @app.app_key,
        redirect_uri: Aliexpress.config.callback_url,
        force_auth: force_auth
      }
      query[:state] = state if state.present?
      query[:uuid] = uuid if uuid.present?

      "#{Aliexpress.config.authorize_url}?#{URI.encode_www_form(query)}"
    end

    def exchange_code!(code, uuid: nil)
      raise Error, "Missing authorization code" if code.blank?

      api_params = { "code" => code.to_s.strip }
      api_params["uuid"] = uuid.to_s if uuid.present?

      body = @client.execute(Aliexpress.config.token_path, api_params)

      token_payload = unwrap_token_body(body)
      persist_token!(token_payload, raw: body)
    end

    def refresh!(refresh_token)
      raise Error, "Missing refresh_token" if refresh_token.blank?

      body = @client.execute("/auth/token/refresh", "refresh_token" => refresh_token)
      token_payload = unwrap_token_body(body)
      persist_token!(token_payload, raw: body)
    end

    attr_reader :app

    private

    def unwrap_token_body(body)
      if body["access_token"].present?
        body
      elsif body["result"].is_a?(Hash)
        body["result"]
      else
        body
      end
    end

    def persist_token!(payload, raw:)
      access_token = payload["access_token"]
      raise Error, "Token response missing access_token: #{payload.inspect}" if access_token.blank?

      expires_in = payload["expires_in"].to_i
      refresh_expires_in = (payload["refresh_expires_in"] || payload["refresh_token_valid_time"]).to_i

      attrs = {
        app_key: @app.app_key,
        access_token: access_token,
        refresh_token: payload["refresh_token"],
        expires_at: expires_in.positive? ? Time.current + expires_in.seconds : nil,
        refresh_expires_at: refresh_expires_time(payload, refresh_expires_in),
        account: payload["account"] || payload["user_nick"],
        user_id: payload["user_id"]&.to_s || payload["seller_id"]&.to_s || payload["account_id"]&.to_s,
        raw_response: raw
      }

      record = persist_sqlite!(attrs)
      Aliexpress::TokenStore.write!(
        attrs.merge(
          id: record&.id || "redis:#{@app.app_key}",
          created_at: record&.created_at || Time.current
        ),
        app_key: @app.app_key
      )
      Aliexpress::TokenStore.fetch(app_key: @app.app_key) ||
        record ||
        raise(Error, "Failed to persist token (SQLite + Redis)")
    end

    def persist_sqlite!(attrs)
      record = if AliExpressToken.column_names.include?("app_key")
        AliExpressToken.where(app_key: @app.app_key).order(created_at: :desc).first_or_initialize
      else
        AliExpressToken.order(created_at: :desc).first_or_initialize
      end
      allowed = %i[access_token refresh_token expires_at refresh_expires_at account user_id raw_response]
      allowed << :app_key if record.respond_to?(:app_key=)
      record.assign_attributes(attrs.slice(*allowed))
      record.save!
      record
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
      Rails.logger.warn("[Aliexpress::Oauth] SQLite persist skipped: #{e.message}")
      nil
    end

    def refresh_expires_time(payload, refresh_expires_in)
      if payload["refresh_token_valid_time"].to_i > 1_000_000_000_000
        Time.zone.at(payload["refresh_token_valid_time"].to_i / 1000.0)
      elsif refresh_expires_in.positive?
        Time.current + refresh_expires_in.seconds
      end
    end
  end
end
