# frozen_string_literal: true

require "cgi"

module Aliexpress
  # OAuth 2.0 helpers for AliExpress Open Platform.
  class Oauth
    class Error < StandardError; end

    def initialize(client: IopClient.new)
      @client = client
    end

    def authorization_url(state: nil, force_auth: true, uuid: nil)
      raise Error, "Set ALIEXPRESS_APP_KEY in .env" unless Aliexpress.config.app_key.present?

      query = {
        response_type: "code",
        client_id: Aliexpress.config.app_key,
        redirect_uri: Aliexpress.config.callback_url,
        force_auth: force_auth
      }
      query[:state] = state if state.present?
      # uuid is optional; only send when explicitly provided (must match token create).
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
          id: record&.id || "redis",
          created_at: record&.created_at || Time.current
        )
      )
      record || Aliexpress::TokenStore.fetch || raise(Error, "Failed to persist token (SQLite + Redis)")
    end

    def persist_sqlite!(attrs)
      record = AliExpressToken.order(created_at: :desc).first_or_initialize
      record.assign_attributes(attrs)
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
