# frozen_string_literal: true

module Aliexpress
  # Redis-backed AppKey / Secret registry.
  # Hash key: aliexpress:oauth:apps  field=app_key  value=JSON{app_secret,label}
  # No TTL — credentials persist until deleted from the console.
  class AppRegistry
    KEY = "aliexpress:oauth:apps"

    Entry = Struct.new(:app_key, :app_secret, :label, keyword_init: true)

    class << self
      def enabled?
        defined?(REDIS) && REDIS.present?
      end

      def all
        return [] unless enabled?

        REDIS.hgetall(KEY).filter_map do |app_key, raw|
          data = JSON.parse(raw)
          secret = (data["app_secret"] || data["secret"]).to_s.strip
          next if app_key.blank? || secret.blank?

          Entry.new(
            app_key: app_key.to_s.strip,
            app_secret: secret,
            label: data["label"].to_s.strip.presence
          )
        end
      rescue Redis::BaseError, JSON::ParserError => e
        Rails.logger.warn("[Aliexpress::AppRegistry] all failed: #{e.message}")
        []
      end

      def upsert!(app_key:, app_secret:, label: nil)
        raise ArgumentError, "Redis 未连接" unless enabled?

        key = app_key.to_s.strip
        secret = app_secret.to_s.strip
        raise ArgumentError, "app_key 不能为空" if key.blank?
        raise ArgumentError, "app_secret 不能为空" if secret.blank?

        payload = {
          app_secret: secret,
          label: label.to_s.strip.presence || key
        }
        REDIS.hset(KEY, key, payload.to_json)
        Aliexpress.reset_apps!
        true
      end

      def delete!(app_key)
        raise ArgumentError, "Redis 未连接" unless enabled?

        key = app_key.to_s.strip
        raise ArgumentError, "app_key 不能为空" if key.blank?

        REDIS.hdel(KEY, key)
        Aliexpress.reset_apps!
        true
      end

      def exists?(app_key)
        return false unless enabled?

        REDIS.hexists(KEY, app_key.to_s.strip)
      rescue Redis::BaseError
        false
      end
    end
  end
end
