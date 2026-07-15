# frozen_string_literal: true

module BasicAuthenticable
  extend ActiveSupport::Concern

  # Paths AliExpress / Render must reach without a password prompt.
  OPEN_PATHS = %w[/callback /oauth/callback /up].freeze

  included do
    before_action :require_http_basic_auth, if: :basic_auth_enabled?
  end

  private

  def basic_auth_enabled?
    ENV["BASIC_AUTH_USER"].present? && ENV["BASIC_AUTH_PASSWORD"].present?
  end

  def require_http_basic_auth
    return if OPEN_PATHS.include?(request.path)

    authenticate_or_request_with_http_basic("Everymarket AliExpress OAuth") do |user, password|
      ActiveSupport::SecurityUtils.secure_compare(user, ENV.fetch("BASIC_AUTH_USER")) &
        ActiveSupport::SecurityUtils.secure_compare(password, ENV.fetch("BASIC_AUTH_PASSWORD"))
    end
  end
end
