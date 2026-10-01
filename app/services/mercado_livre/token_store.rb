# frozen_string_literal: true

module MercadoLivre
  # Redis-backed token persistence (Upstash-friendly).
  # Key: mercadolivre:oauth:token:{app_key}  (no legacy key — ML tokens are per-app from day one)
  class TokenStore
    KEY_PREFIX = "mercadolivre:oauth:token"
    CODE_CACHE_PREFIX = "mercadolivre:oauth:code:"

    # ML access_token expires_in ≈ 6h; refresh_token rotates on every refresh and
    # remains valid while used (≈10 days without use). Keep the record alive past
    # the access window so workers have time to refresh.
    DEFAULT_TTL = 30.days
    TTL_BUFFER = 6.hours

    Token = Struct.new(
      :id, :access_token, :refresh_token, :expires_at, :refresh_expires_at,
      :account, :user_id, :site_id, :app_key, :created_at, :updated_at,
      keyword_init: true
    ) do
      def expired?
        expires_at.present? && expires_at <= Time.current
      end

      def usable?
        access_token.present? && !expired?
      end
    end

    class << self
      def enabled?
        defined?(REDIS) && REDIS.present?
      end

      def redis_key(app_key)
        key = app_key.to_s.strip
        raise ArgumentError, "app_key 不能为空" if key.blank?

        "#{KEY_PREFIX}:#{key}"
      end

      def write!(attrs, app_key: nil)
        return false unless enabled?

        app_key = (app_key || attrs[:app_key] || attrs["app_key"]).to_s.strip
        payload = normalize(attrs, app_key: app_key)
        ttl = ttl_seconds(payload)

        key = redis_key(app_key)
        REDIS.set(key, payload.to_json)
        REDIS.expire(key, ttl) if ttl.positive?
        true
      end

      def fetch(app_key:)
        return nil unless enabled?

        key = app_key.to_s.strip
        return nil if key.blank?

        raw = REDIS.get(redis_key(key))
        return nil if raw.blank?

        token_from_json(raw, app_key: key)
      rescue JSON::ParserError, Redis::BaseError => e
        Rails.logger.warn("[MercadoLivre::TokenStore] fetch failed: #{e.message}")
        nil
      end

      def fetch_all
        MercadoLivre.apps.filter_map { |app| fetch(app_key: app.app_key) }
      end

      def clear!(app_key: nil)
        return unless enabled?

        if app_key.to_s.strip.present?
          REDIS.del(redis_key(app_key))
        else
          MercadoLivre.apps.each { |app| REDIS.del(redis_key(app.app_key)) }
        end
      end

      # Idempotent OAuth code exchange (browser reload / double submission)
      def cached_token_id_for_code(code)
        return nil unless enabled?

        REDIS.get(code_cache_key(code))
      end

      def cache_code_token_id!(code, token_id, expires_in: 10.minutes)
        return unless enabled?

        REDIS.setex(code_cache_key(code), expires_in.to_i, token_id.to_s)
      end

      private

      def code_cache_key(code)
        "#{CODE_CACHE_PREFIX}#{Digest::SHA256.hexdigest(code.to_s)}"
      end

      def token_from_json(raw, app_key:)
        data = JSON.parse(raw)
        Token.new(
          id: data["id"] || "redis",
          access_token: data["access_token"],
          refresh_token: data["refresh_token"],
          expires_at: parse_time(data["expires_at"]),
          refresh_expires_at: parse_time(data["refresh_expires_at"]),
          account: data["account"],
          user_id: data["user_id"],
          site_id: data["site_id"],
          app_key: data["app_key"].presence || app_key,
          created_at: parse_time(data["created_at"]) || Time.current,
          updated_at: parse_time(data["updated_at"]) || Time.current
        )
      end

      def normalize(attrs, app_key:)
        {
          id: attrs[:id] || attrs["id"] || "redis",
          app_key: app_key.presence,
          access_token: attrs[:access_token] || attrs["access_token"],
          refresh_token: attrs[:refresh_token] || attrs["refresh_token"],
          expires_at: time_iso(attrs[:expires_at] || attrs["expires_at"]),
          refresh_expires_at: time_iso(attrs[:refresh_expires_at] || attrs["refresh_expires_at"]),
          account: attrs[:account] || attrs["account"],
          user_id: attrs[:user_id] || attrs["user_id"],
          site_id: attrs[:site_id] || attrs["site_id"],
          created_at: time_iso(attrs[:created_at] || attrs["created_at"] || Time.current),
          updated_at: time_iso(Time.current)
        }
      end

      def ttl_seconds(payload)
        target = parse_time(payload[:expires_at]) ||
                 parse_time(payload[:refresh_expires_at])
        return DEFAULT_TTL.to_i if target.nil?

        [ (target - Time.current).to_i + TTL_BUFFER.to_i, 60 ].max
      end

      def time_iso(value)
        return nil if value.blank?
        return value.iso8601 if value.respond_to?(:iso8601)

        parse_time(value)&.iso8601
      end

      def parse_time(value)
        return nil if value.blank?
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

        Time.zone.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
