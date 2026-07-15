# frozen_string_literal: true

# Upstash Redis (REDIS_URL) is preferred in production for OAuth token storage.
# Falls back to nil when unset — tokens then persist only in SQLite.
REDIS =
  if ENV["REDIS_URL"].present?
    Redis.new(
      url: ENV["REDIS_URL"],
      ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE },
      timeout: 5
    )
  end
