# frozen_string_literal: true

class HomeController < ApplicationController
  def index
    @configured = Aliexpress.configured?
    @callback_url = Aliexpress.config.callback_url
    @token = AliExpressToken.current_token
    @app_key = Aliexpress.config.app_key
    @authorize_preview = Aliexpress::Oauth.new.authorization_url(state: "preview") if @configured
  rescue Aliexpress::Oauth::Error
    @authorize_preview = nil
  end
end
