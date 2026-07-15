# frozen_string_literal: true

class ProductsController < ApplicationController
  # GET /products/:id?local_country=US&local_language=en
  def show
    client = Aliexpress::ProductClient.new
    @product_id = params[:id]
    @local_country = params.fetch(:local_country, "US")
    @local_language = params.fetch(:local_language, "en")
    @raw = client.get(
      product_id: @product_id,
      local_country: @local_country,
      local_language: @local_language
    )
    @skus = Aliexpress::ProductClient.extract_skus(@raw)
  rescue Aliexpress::Oauth::Error, Aliexpress::IopClient::Error => e
    @error = e.message
    render :show, status: :unprocessable_entity
  end
end
