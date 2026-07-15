# frozen_string_literal: true

module Aliexpress
  # Redis-backed token persistence (Upstash-friendly).
  # Keys auto-expire via Redis EXPIRE; access_token expiry is also tracked in JSON.
  class TokenStore
    KEY = "aliexpress:oauth:token"
    CODE_CACHE_PREFIX = "aliexpress:oauth:code:"

    Token = Struct.new(
      :id, :access_token, :refresh_token, :expires_at, :refresh_expires_at,
      :account, :user_id, :raw_response, :created_at, :updated_at,
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

      def write!(attrs)
        return false unless enabled?

        payload = normalize(attrs)
        ttl = ttl_seconds(payload)
        REDIS.set(KEY, payload.to_json)
        REDIS.expire(KEY, ttl) if ttl.positive?
        true
      end

      def fetch
        return nil unless enabled?

        raw = REDIS.get(KEY)
        return nil if raw.blank?

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
          updated_at: parse_time(data["updated_at"]) || Time.current
        )
      rescue JSON::ParserError, Redis::BaseError => e
        Rails.logger.warn("[Aliexpress::TokenStore] fetch failed: #{e.message}")
        nil
      end

      def clear!
        return unless enabled?

        REDIS.del(KEY)
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

      def normalize(attrs)
        {
          id: attrs[:id] || attrs["id"] || "redis",
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
