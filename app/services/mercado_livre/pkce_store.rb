# frozen_string_literal: true

module MercadoLivre
  # Redis-backed PKCE verifier storage. Keyed by OAuth state so the verifier
  # survives the browser round-trip AND spans instances (local console generates
  # the link, the production /ml/callback redeems it — both share the same Redis).
  # Key: mercadolivre:oauth:pkce:{state} — TTL 15min, deleted after exchange.
  class PkceStore
    KEY_PREFIX = "mercadolivre:oauth:pkce"
    TTL = 15.minutes

    class << self
      def enabled?
        defined?(REDIS) && REDIS.present?
      end

      def key_for(state)
        "#{KEY_PREFIX}:#{state.to_s.strip}"
      end

      # @return [String, nil] the verifier (nil if Redis missing / entry expired)
      def get(state)
        return nil unless enabled?
        return nil if state.blank?

        REDIS.get(key_for(state))
      rescue Redis::BaseError => e
        Rails.logger.warn("[MercadoLivre::PkceStore] get failed: #{e.message}")
        nil
      end

      def set!(state, verifier)
        return false unless enabled?
        return false if state.blank? || verifier.blank?

        REDIS.setex(key_for(state), TTL.to_i, verifier.to_s)
        true
      rescue Redis::BaseError => e
        Rails.logger.warn("[MercadoLivre::PkceStore] set failed: #{e.message}")
        false
      end

      def delete!(state)
        return false unless enabled?
        return false if state.blank?

        REDIS.del(key_for(state)).to_i.positive?
      rescue Redis::BaseError => e
        Rails.logger.warn("[MercadoLivre::PkceStore] delete failed: #{e.message}")
        false
      end
    end
  end
end
