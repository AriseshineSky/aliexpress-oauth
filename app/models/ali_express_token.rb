# frozen_string_literal: true

class AliExpressToken < ApplicationRecord
  validates :access_token, presence: true

  scope :current, -> { order(created_at: :desc) }
  scope :for_app, ->(app_key) { where(app_key: app_key.to_s) }

  def self.latest(app_key: nil)
    scope = current
    if app_key.present? && column_names.include?("app_key")
      scope = scope.for_app(app_key)
    end
    scope.first
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
    Rails.logger.warn("[AliExpressToken] SQLite unavailable: #{e.message}")
    nil
  end

  # Prefer Upstash Redis (survives Render free-tier filesystem resets), then SQLite.
  def self.current_token(app_key: nil)
    key = app_key.presence || Aliexpress.primary_app&.app_key
    Aliexpress::TokenStore.fetch(app_key: key) || latest(app_key: key)
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
