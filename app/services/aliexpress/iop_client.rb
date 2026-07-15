# frozen_string_literal: true

require "digest"
require "json"
require "openssl"

module Aliexpress
  # IOP REST client — signature per AliExpress Open Platform docs:
  # HMAC-SHA256(key=app_secret, data=api_path + sorted(key+value pairs))
  class IopClient
    class Error < StandardError
      attr_reader :code, :body, :status

      def initialize(message, code: nil, body: nil, status: nil)
        super(message)
        @code = code
        @body = body
        @status = status
      end
    end

    def initialize(app_key: Aliexpress.config.app_key, app_secret: Aliexpress.config.app_secret, base_url: Aliexpress.config.api_base)
      @app_key = app_key
      @app_secret = app_secret
      # Trailing slash so Faraday relative paths stay under /rest/
      @base_url = "#{base_url.to_s.chomp("/")}/"
    end

    # +api_path+ examples: "/auth/token/create", "aliexpress.ds.product.get"
    def execute(api_path, api_params = {}, access_token: nil)
      api_name = normalize_api_name(api_path)
      params = system_params(access_token).merge(stringify_keys(api_params))
      params["sign"] = sign(params, api_name: api_name)

      # Faraday: relative path (no leading slash) under base /rest/
      path = api_name.sub(%r{\A/}, "")
      response = connection.post(path) do |req|
        req.headers["Content-Type"] = "application/x-www-form-urlencoded;charset=utf-8"
        req.headers["Accept"] = "application/json"
        req.body = URI.encode_www_form(params)
      end

      Rails.logger.info("[AliExpress IOP] POST #{@base_url}#{path} status=#{response.status} bytes=#{response.body.to_s.bytesize}")
      parse_response(response)
    end

    private

    def connection
      @connection ||= Faraday.new(url: @base_url) do |f|
        f.adapter Faraday.default_adapter
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    def system_params(access_token)
      params = {
        "app_key" => @app_key,
        "timestamp" => (Time.now.to_f * 1000).to_i.to_s,
        "sign_method" => "sha256"
      }
      # simplify can break some auth endpoints; only add for business APIs when needed
      params["access_token"] = access_token if access_token.present?
      params
    end

    # Official algorithm:
    #   basestring = apiName + sorted_key_value_pairs
    #   sign = HMAC_SHA256(app_secret, basestring).hex.upcase
    def sign(params, api_name:)
      data = "#{api_name}#{sorted_payload(params)}"
      OpenSSL::HMAC.hexdigest("SHA256", @app_secret, data).upcase
    end

    def sorted_payload(params)
      params
        .reject { |k, v| k.to_s == "sign" || v.nil? || v.to_s.empty? }
        .sort_by { |k, _| k.to_s }
        .map { |k, v| "#{k}#{v}" }
        .join
    end

    def normalize_api_name(api_path)
      path = api_path.to_s
      path.start_with?("/") ? path : "/#{path}"
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), memo| memo[k.to_s] = v.to_s }
    end

    def parse_response(response)
      raw = response.body.to_s
      if raw.blank?
        raise Error.new(
          "Empty response from AliExpress (HTTP #{response.status})",
          status: response.status,
          body: raw
        )
      end

      body = JSON.parse(raw)

      error_code = body["code"] || body["error_code"] || body["error_response"]&.dig("code")
      if error_code.present? && !%w[0 200].include?(error_code.to_s)
        message = body["message"] || body["error_msg"] || body["error_response"]&.dig("msg") || "AliExpress API error"
        raise Error.new(message, code: error_code, body: body, status: response.status)
      end

      body
    rescue JSON::ParserError
      raise Error.new(
        "Invalid JSON from AliExpress (HTTP #{response.status}): #{raw.truncate(300)}",
        body: raw,
        status: response.status
      )
    end
  end
end
