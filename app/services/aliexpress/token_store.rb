# frozen_string_literal: true

module Aliexpress
  # Redis-backed token persistence (Upstash-friendly).
  # Keys: aliexpress:oauth:token:{app_key}  (+ legacy aliexpress:oauth:token for primary)
  class TokenStore
    LEGACY_KEY = "aliexpress:oauth:token"
    CODE_CACHE_PREFIX = "aliexpress:oauth:code:"

    Token = Struct.new(
      :id, :access_token, :refresh_token, :expires_at, :refresh_expires_at,
      :account, :user_id, :raw_response, :created_at, :updated_at, :app_key,
      keyword_init: true
    ) do
      def expired?
        expires_at.present? && expires_at <= Time.current
      end

      def usable?
        access_token.present? && !expired?
      end

      def refresh_expired?
        refresh_expires_at.present? && refresh_expires_at <= Time.current
      end
    end

    class << self
      def enabled?
        defined?(REDIS) && REDIS.present?
      end

      def redis_key(app_key)
        key = app_key.to_s.strip
        return LEGACY_KEY if key.blank?

        "#{LEGACY_KEY}:#{key}"
      end

      def write!(attrs, app_key: nil)
        return false unless enabled?

        app_key = (app_key || attrs[:app_key] || attrs["app_key"]).to_s.strip
        payload = normalize(attrs, app_key: app_key)
        ttl = ttl_seconds(payload)
        key = redis_key(app_key)
        REDIS.set(key, payload.to_json)
        REDIS.expire(key, ttl) if ttl.positive?

        # Keep legacy key in sync for the primary app (old aliexpress-ds workers).
        primary = Aliexpress.primary_app
        if primary && app_key == primary.app_key && key != LEGACY_KEY
          REDIS.set(LEGACY_KEY, payload.to_json)
          REDIS.expire(LEGACY_KEY, ttl) if ttl.positive?
        end

        true
      end

      def fetch(app_key: nil)
        return nil unless enabled?

        app_key = app_key.to_s.strip.presence || Aliexpress.primary_app&.app_key
        return nil if app_key.blank?

        raw = REDIS.get(redis_key(app_key))
        # Migrate: primary may still only exist on legacy key.
        if raw.blank? && Aliexpress.primary_app&.app_key == app_key
          raw = REDIS.get(LEGACY_KEY)
          if raw.present?
            data = JSON.parse(raw)
            write!(data, app_key: app_key)
          end
        end
        return nil if raw.blank?

        token_from_json(raw, app_key: app_key)
      rescue JSON::ParserError, Redis::BaseError => e
        Rails.logger.warn("[Aliexpress::TokenStore] fetch failed: #{e.message}")
        nil
      end

      def fetch_all
        Aliexpress.apps.filter_map { |app| fetch(app_key: app.app_key) }
      end

      def clear!(app_key: nil)
        return unless enabled?

        app_key = app_key.to_s.strip
        if app_key.present?
          REDIS.del(redis_key(app_key))
          REDIS.del(LEGACY_KEY) if Aliexpress.primary_app&.app_key == app_key
        else
          Aliexpress.apps.each { |app| REDIS.del(redis_key(app.app_key)) }
          REDIS.del(LEGACY_KEY)
        end
      end

      # Idempotent OAuth code exchange (shared across free-tier dyno restarts)
      def cached_token_id_for_code(code)
        return Rails.cache.read(code_cache_key(code)) unless enabled?

        REDIS.get(code_cache_key(code))
      end

      def cache_code_token_id!(code, token_id, expires_in: 10.minutes)
        key = code_cache_key(code)
        if enabled?
          REDIS.setex(key, expires_in.to_i, token_id.to_s)
        else
          Rails.cache.write(key, token_id, expires_in: expires_in)
        end
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
          raw_response: data["raw_response"],
          created_at: parse_time(data["created_at"]) || Time.current,
          updated_at: parse_time(data["updated_at"]) || Time.current,
          app_key: data["app_key"].presence || app_key
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
          raw_response: attrs[:raw_response] || attrs["raw_response"],
          created_at: time_iso(attrs[:created_at] || attrs["created_at"] || Time.current),
          updated_at: time_iso(Time.current)
        }
      end

      def ttl_seconds(payload)
        refresh_at = parse_time(payload[:refresh_expires_at])
        access_at = parse_time(payload[:expires_at])
        deadline = [ refresh_at, access_at ].compact.max
        return 30.days.to_i if deadline.nil?

        [ (deadline - Time.current).to_i, 60 ].max
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
