# frozen_string_literal: true

class AliExpressToken < ApplicationRecord
  validates :access_token, presence: true

  scope :current, -> { order(created_at: :desc) }

  def self.latest
    current.first
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
    Rails.logger.warn("[AliExpressToken] SQLite unavailable: #{e.message}")
    nil
  end

  # Prefer Upstash Redis (survives Render free-tier filesystem resets), then SQLite.
  def self.current_token
    Aliexpress::TokenStore.fetch || latest
  end

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
