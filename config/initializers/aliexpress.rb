# frozen_string_literal: true

module Aliexpress
  class << self
    def config
      @config ||= ActiveSupport::OrderedOptions.new.tap do |c|
        c.app_key = ENV.fetch("ALIEXPRESS_APP_KEY", "")
        c.app_secret = ENV.fetch("ALIEXPRESS_APP_SECRET", "")
        c.callback_url = ENV.fetch("ALIEXPRESS_CALLBACK_URL", "http://localhost:3000/callback")
        c.api_base = ENV.fetch("ALIEXPRESS_API_BASE", "https://api-sg.aliexpress.com/rest")
        c.authorize_url = ENV.fetch("ALIEXPRESS_AUTHORIZE_URL", "https://api-sg.aliexpress.com/oauth/authorize")
        c.token_path = ENV.fetch("ALIEXPRESS_TOKEN_PATH", "/auth/token/create")
      end
    end

    def configured?
      key = config.app_key.to_s
      secret = config.app_secret.to_s
      key.present? && secret.present? &&
        !key.start_with?("your_") && !secret.start_with?("your_")
    end
  end
end
