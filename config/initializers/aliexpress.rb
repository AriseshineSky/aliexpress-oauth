# frozen_string_literal: true

module Aliexpress
  App = Struct.new(:app_key, :app_secret, :label, :primary, keyword_init: true) do
    def primary?
      primary
    end

    def display_name
      label.presence || app_key
    end
  end

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
      apps.any?
    end

    # All registered apps (primary + extras). Shared Callback URL is fine —
    # tokens are stored under aliexpress:oauth:token:{app_key}.
    def apps
      @apps ||= build_apps
    end

    def find_app(app_key)
      key = app_key.to_s.strip
      apps.find { |a| a.app_key == key }
    end

    def primary_app
      apps.find(&:primary?) || apps.first
    end

    def reset_apps!
      @apps = nil
    end

    private

    def build_apps
      list = []
      seen = {}

      add = lambda do |key, secret, label:, primary: false|
        key = key.to_s.strip
        secret = secret.to_s.strip
        return if key.blank? || secret.blank?
        return if key.start_with?("your_") || secret.start_with?("your_")
        return if seen[key]

        seen[key] = true
        list << App.new(app_key: key, app_secret: secret, label: label, primary: primary)
      end

      add.call(config.app_key, config.app_secret, label: ENV.fetch("ALIEXPRESS_APP_LABEL", "primary"), primary: true)

      # ALIEXPRESS_APP_KEY_2 / ALIEXPRESS_APP_SECRET_2 … _9
      (2..9).each do |i|
        add.call(
          ENV["ALIEXPRESS_APP_KEY_#{i}"],
          ENV["ALIEXPRESS_APP_SECRET_#{i}"],
          label: ENV.fetch("ALIEXPRESS_APP_LABEL_#{i}", "app#{i}"),
          primary: false
        )
      end

      # Optional JSON: [{"app_key":"539578","app_secret":"...","label":"vps2"}]
      raw_json = ENV["ALIEXPRESS_APPS_JSON"].to_s.strip
      if raw_json.present?
        JSON.parse(raw_json).each_with_index do |row, idx|
          next unless row.is_a?(Hash)

          add.call(
            row["app_key"] || row["key"],
            row["app_secret"] || row["secret"],
            label: row["label"].presence || "json#{idx + 1}",
            primary: false
          )
        end
      end

      list
    rescue JSON::ParserError => e
      Rails.logger.warn("[Aliexpress] ALIEXPRESS_APPS_JSON invalid: #{e.message}")
      list
    end
  end
end
