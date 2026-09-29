Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "home#index"
  post "oauth/refresh", to: "home#refresh_token", as: :refresh_token
  post "apps", to: "home#create_app", as: :apps
  delete "apps/:app_key", to: "home#destroy_app", as: :app

  # AliExpress OAuth — Console Callback URL uses /callback
  # e.g. https://aliexpress-oauth.onrender.com/callback
  get "callback", to: "oauth#callback", as: :callback

  get "oauth/authorize", to: "oauth#authorize", as: :oauth_authorize
  get "oauth/callback",  to: "oauth#callback",  as: :oauth_callback
  get "oauth/success",   to: "oauth#success",   as: :oauth_success
  get "oauth/failure",   to: "oauth#failure",   as: :oauth_failure

  # Optional: fetch dropshipping product prices after auth
  get "products/:id", to: "products#show", as: :product

  # Mercado Livre (MLB) — official read-only API, shared Redirect URI per Client ID.
  # e.g. https://aliexpress-oauth.onrender.com/ml/callback
  post "ml/apps", to: "mercado_livre#create_app", as: :ml_apps
  delete "ml/apps/:app_key", to: "mercado_livre#destroy_app", as: :ml_app
  get "ml/authorize", to: "mercado_livre#authorize", as: :ml_authorize
  get "ml/callback", to: "mercado_livre#callback", as: :ml_callback
  post "ml/refresh", to: "mercado_livre#refresh", as: :ml_refresh
  get "ml/success", to: "mercado_livre#success", as: :ml_success
  get "ml/items/:item_id", to: "mercado_livre#item", as: :ml_item
end
