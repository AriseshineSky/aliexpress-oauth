# frozen_string_literal: true

require "cgi"

module MercadoLivre
  # OAuth 2.0 helpers for Mercado Livre Brasil.
  # Docs: https://developers.mercadolivre.com.br/pt_br/autenticacao-e-autorizacao
  class Oauth
    class Error < StandardError; end

    def initialize(app: nil, client: nil)
      @app = app || MercadoLivre.primary_app
      raise Error, "No Mercado Livre app configured" if @app.nil?

      @client = client || Client.new
    end

    def self.for_app_key(app_key)
      app = MercadoLivre.find_app(app_key) || raise(Error, "Unknown app_key=#{app_key.inspect} — add it via console (Redis) or env")
      new(app: app)
    end

    # state embeds app_key so /ml/callback can pick the right Secret without session.
    def self.build_state(app_key, nonce: SecureRandom.hex(16))
      "ml.v1.#{app_key}.#{nonce}"
    end

    def self.parse_state(state)
      parts = state.to_s.split(".", 4)
      return {} unless parts.size == 4 && parts[0] == "ml" && parts[1] == "v1" && parts[2].present?

      { app_key: parts[2], nonce: parts[3] }
    end

    attr_reader :app

    def authorization_url(state: nil, redirect_uri: nil, code_challenge: nil, code_challenge_method: "S256")
      query = {
        response_type: "code",
        client_id: @app.app_key,
        redirect_uri: redirect_uri || MercadoLivre.config.callback_url
      }
      query[:state] = state if state.present?
      if code_challenge.present?
        query[:code_challenge] = code_challenge
        query[:code_challenge_method] = code_challenge_method
      end

      "#{MercadoLivre.config.authorize_url}?#{URI.encode_www_form(query)}"
    end

    def exchange_code!(code, code_verifier: nil)
      raise Error, "Missing authorization code" if code.blank?

      body = @client.exchange_token!(
        grant_type: "authorization_code",
        client_id: @app.app_key,
        client_secret: @app.app_secret,
        code: code.to_s.strip,
        redirect_uri: MercadoLivre.config.callback_url,
        code_verifier: code_verifier
      )
      persist!(body)
    end

    def refresh!(refresh_token)
      raise Error, "Missing refresh_token" if refresh_token.blank?

      body = @client.exchange_token!(
        grant_type: "refresh_token",
        client_id: @app.app_key,
        client_secret: @app.app_secret,
        refresh_token: refresh_token.to_s.strip
      )
      persist!(body)
    end

    private

    def persist!(payload)
      access_token = payload["access_token"]
      raise Error, "Token response missing access_token: #{payload.inspect}" if access_token.blank?

      expires_in = payload["expires_in"].to_i
      attrs = {
        app_key: @app.app_key,
        access_token: access_token,
        refresh_token: payload["refresh_token"],
        expires_at: expires_in.positive? ? Time.current + expires_in.seconds : nil,
        account: nil,
        user_id: payload["user_id"]&.to_s
      }

      MercadoLivre::TokenStore.write!(attrs, app_key: @app.app_key)
      token = MercadoLivre::TokenStore.fetch(app_key: @app.app_key)
      raise Error, "Failed to persist token to Redis" if token.nil?

      enrich_with_identity!(token)
      MercadoLivre::TokenStore.fetch(app_key: @app.app_key) || token
    end

    # Best-effort: fetch nickname / user info from /users/me; never fails the flow.
    def enrich_with_identity!(token)
      body = @client.me(access_token: token.access_token)
      MercadoLivre::TokenStore.write!(
        token.to_h.compact.merge(
          account: body["nickname"].presence,
          user_id: body["id"].to_s.presence || token.user_id
        ),
        app_key: @app.app_key
      )
      nil
    rescue MercadoLivre::Client::Error => e
      Rails.logger.warn("[MercadoLivre::Oauth] users/me skipped: #{e.message}")
      nil
    end
  end
end
