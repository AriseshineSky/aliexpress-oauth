# frozen_string_literal: true

class HomeController < ApplicationController
  def index
    @configured = Aliexpress.configured?
    @callback_url = Aliexpress.config.callback_url
    @token = AliExpressToken.current_token
  end
end
