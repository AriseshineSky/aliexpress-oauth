# frozen_string_literal: true

module MercadoLivre
  App = Struct.new(:app_key, :app_secret, :label, :primary, :source, keyword_init: true) do
    def primary?
      primary
    end

    def redis?
      source == :redis
    end

    def env?
      source == :env
    end

    def display_name
      label.presence || app_key
    end
  end

  class << self
    def config
      @config ||= ActiveSupport::OrderedOptions.new.tap do |c|
        c.app_key = ENV.fetch("MERCADOLIVRE_APP_KEY", "")
        c.app_secret = ENV.fetch("MERCADOLIVRE_APP_SECRET", "")
        c.callback_url = ENV.fetch("MERCADOLIVRE_CALLBACK_URL", "http://localhost:3000/ml/callback")
        c.authorize_url = ENV.fetch("MERCADOLIVRE_AUTHORIZE_URL", "https://auth.mercadolivre.com.br/authorization")
        c.api_base = ENV.fetch("MERCADOLIVRE_API_BASE", "https://api.mercadolibre.com")
      end
    end

    def configured?
      apps.any?
    end

    # Env apps (optional bootstrap) + Redis registry. Each ML app has its own
    # token under mercadolivre:oauth:token:{app_key}, so one shared Redirect
    # URI is safe across multiple Client IDs.
    def apps
      build_apps
    end

    def find_app(app_key)
      key = app_key.to_s.strip
      apps.find { |a| a.app_key == key }
    end

    def primary_app
      apps.find(&:primary?) || apps.first
    end

    def reset_apps!
      # Kept for callers after registry writes; apps are rebuilt each request.
      nil
    end

    private

    def build_apps
      list = []
      seen = {}

      add = lambda do |key, secret, label:, primary: false, source:|
        key = key.to_s.strip
        secret = secret.to_s.strip
        return if key.blank? || secret.blank?
        return if key.start_with?("your_") || secret.start_with?("your_")
        return if seen[key]

        seen[key] = true
        list << App.new(
          app_key: key,
          app_secret: secret,
          label: label,
          primary: primary,
          source: source
        )
      end

      # Optional env bootstrap (merged with Redis; Redis wins — it can self-serve via console).
      add.call(
        config.app_key,
        config.app_secret,
        label: ENV.fetch("MERCADOLIVRE_APP_LABEL", "primary"),
        primary: true,
        source: :env
      )

      # Preferred: apps registered in Redis via the console
      MercadoLivre::AppRegistry.all.each do |entry|
        add.call(
          entry.app_key,
          entry.app_secret,
          label: entry.label.presence || entry.app_key,
          primary: list.empty?,
          source: :redis
        )
      end

      list
    rescue JSON::ParserError, Redis::BaseError => e
      Rails.logger.warn("[MercadoLivre] registry load failed: #{e.message}")
      list
    end
  end
end
