# frozen_string_literal: true

module MercadoLivre
  # REST client for Mercado Livre Open API (https://developers.mercadolivre.com.br/)
  class Client
    class Error < StandardError
      attr_reader :code, :body, :status

      def initialize(message, code: nil, body: nil, status: nil)
        super(message)
        @code = code
        @body = body
        @status = status
      end
    end

    OAUTH_TOKEN_URL = "https://api.mercadolibre.com/oauth/token"

    def initialize
      @base_url = "#{MercadoLivre.config.api_base.to_s.chomp("/")}/"
    end

    # POST /oauth/token — authorization_code or refresh_token grant
    def exchange_token!(grant_type:, client_id:, client_secret:, code: nil, refresh_token: nil, redirect_uri: nil)
      params = {
        "grant_type" => grant_type,
        "client_id" => client_id,
        "client_secret" => client_secret
      }
      params["code"] = code.to_s if code.present?
      params["refresh_token"] = refresh_token.to_s if refresh_token.present?
      params["redirect_uri"] = redirect_uri.to_s if redirect_uri.present?

      response = connection.post do |req|
        req.url "oauth/token"
        req.headers["Content-Type"] = "application/x-www-form-urlencoded;charset=utf-8"
        req.headers["Accept"] = "application/json"
        req.body = URI.encode_www_form(params)
      end
      parse_response(response)
    end

    # GET an API resource (Bearer auth optional — /users/me needs it; /items is public).
    def get(path, access_token: nil)
      response = connection.get(path.to_s.sub(%r{\A/}, "")) do |req|
        req.headers["Authorization"] = "Bearer #{access_token}" if access_token.present?
        req.headers["Accept"] = "application/json"
      end
      parse_response(response)
    end

    def me(access_token:)
      get("users/me", access_token: access_token)
    end

    def item(item_id, access_token: nil)
      get("items/#{item_id}", access_token: access_token)
    end

    private

    def connection
      @connection ||= Faraday.new(url: @base_url) do |f|
        f.adapter Faraday.default_adapter
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def parse_response(response)
      raw = response.body.to_s
      if raw.blank?
        raise Error.new("Empty response from Mercado Livre (HTTP #{response.status})", status: response.status, body: raw)
      end

      body = JSON.parse(raw)

      error_message = body["error_description"].presence || body["message"].presence || body["error"].presence
      if response.status >= 400 || error_message.present?
        raise Error.new(
          error_message || "Mercado Livre API error (HTTP #{response.status})",
          code: body["error"],
          body: body,
          status: response.status
        )
      end

      body
    rescue JSON::ParserError
      raise Error.new(
        "Invalid JSON from Mercado Livre (HTTP #{response.status}): #{raw.truncate(300)}",
        body: raw,
        status: response.status
      )
    end
  end
end
