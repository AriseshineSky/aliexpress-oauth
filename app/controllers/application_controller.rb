# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include BasicAuthenticable

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Skip OAuth callback — AliExpress may return via embedded / older WebViews.
  allow_browser versions: :modern, except: :callback

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes
end
