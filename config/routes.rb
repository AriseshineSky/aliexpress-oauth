Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "home#index"

  # AliExpress OAuth — Console Callback URL uses /callback
  # e.g. https://everymarket.onrender.com/callback
  get "callback", to: "oauth#callback", as: :callback

  get "oauth/authorize", to: "oauth#authorize", as: :oauth_authorize
  get "oauth/callback",  to: "oauth#callback",  as: :oauth_callback
  get "oauth/success",   to: "oauth#success",   as: :oauth_success
  get "oauth/failure",   to: "oauth#failure",   as: :oauth_failure

  # Optional: fetch dropshipping product prices after auth
  get "products/:id", to: "products#show", as: :product
end
