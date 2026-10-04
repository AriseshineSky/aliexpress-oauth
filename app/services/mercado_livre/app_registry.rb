# frozen_string_literal: true

module MercadoLivre
  # Redis-backed App credential registry (Mercado Livre).
  # Hash key: mercadolivre:oauth:apps  field=app_key (= Client ID)  value=JSON{app_secret,label,site}
  # No TTL — credentials persist until deleted from the console.
  class AppRegistry
    KEY = "mercadolivre:oauth:apps"

    Entry = Struct.new(:app_key, :app_secret, :label, :site, keyword_init: true)

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
            label: data["label"].to_s.strip.presence,
            site: data["site"].to_s.strip.presence
          )
        end
      rescue Redis::BaseError, JSON::ParserError => e
        Rails.logger.warn("[MercadoLivre::AppRegistry] all failed: #{e.message}")
        []
      end

      def upsert!(app_key:, app_secret:, label: nil, site: nil)
        raise ArgumentError, "Redis 未连接" unless enabled?

        key = app_key.to_s.strip
        secret = app_secret.to_s.strip
        raise ArgumentError, "Client ID 不能为空" if key.blank?
        raise ArgumentError, "Client Secret 不能为空" if secret.blank?

        payload = {
          app_secret: secret,
          label: label.to_s.strip.presence || key,
          site: MercadoLivre.normalize_site(site, strict: true)
        }
        REDIS.hset(KEY, key, payload.to_json)
        MercadoLivre.reset_apps!
        true
      end

      # 只改站点（不需重填 Secret）：已登记的 MLB App 发现其实是墨西哥账号时切到 MLM。
      # @return [String] 新的 site_id
      def update_site!(app_key, site)
        raise ArgumentError, "Redis 未连接" unless enabled?

        key = app_key.to_s.strip
        raise ArgumentError, "Client ID 不能为空" if key.blank?

        raw = REDIS.hget(KEY, key)
        raise ArgumentError, "App #{key} 不在 Redis（可能来自环境变量，请改 env）" if raw.blank?

        data = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          raise ArgumentError, "App #{key} 的 Redis 数据已损坏，请重新保存一次凭证"
        end

        secret = (data["app_secret"] || data["secret"]).to_s.strip
        raise ArgumentError, "App #{key} 缺少 Client Secret，请重新保存凭证" if secret.blank?

        payload = {
          app_secret: secret,
          label: data["label"].to_s.strip.presence || key,
          site: MercadoLivre.normalize_site(site, strict: true)
        }
        REDIS.hset(KEY, key, payload.to_json)
        MercadoLivre.reset_apps!
        payload[:site]
      end

      def delete!(app_key)
        raise ArgumentError, "Redis 未连接" unless enabled?

        key = app_key.to_s.strip
        raise ArgumentError, "Client ID 不能为空" if key.blank?

        REDIS.hdel(KEY, key)
        MercadoLivre.reset_apps!
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
