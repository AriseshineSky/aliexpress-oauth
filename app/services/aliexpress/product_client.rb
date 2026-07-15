# frozen_string_literal: true

module Aliexpress
  # Thin wrapper around aliexpress.ds.product.get for dropshipping prices.
  class ProductClient
    API_NAME = "aliexpress.ds.product.get"

    def self.extract_skus(body)
      result = body.dig("result") || body.dig("aliexpress_ds_product_get_response", "result") || body
      skus = result["ae_op_aeos_product_sku_dto_list"] ||
             result.dig("aeop_ae_product_s_k_us", "aeop_ae_product_sku") ||
             []
      skus = [ skus ] unless skus.is_a?(Array)

      skus.map do |sku|
        {
          sku_id: sku["sku_id"] || sku["id"],
          sku_attr: sku["sku_attr"] || sku["aeop_s_k_u_property_list"],
          sku_price: sku["sku_price"],
          offer_sale_price: sku["offer_sale_price"],
          sku_stock: sku["sku_stock"] || sku["ipm_sku_stock"],
          currency_code: sku["currency_code"]
        }
      end
    end

    def initialize(client: IopClient.new, access_token: nil)
      @client = client
      @access_token = access_token || resolve_token!
    end

    def get(product_id:, local_country: "US", local_language: "en", **extra)
      @client.execute(
        API_NAME,
        {
          product_id: product_id,
          local_country: local_country,
          local_language: local_language
        }.merge(extra),
        access_token: @access_token
      )
    end

    def sku_prices(product_id:, **opts)
      self.class.extract_skus(get(product_id: product_id, **opts))
    end

    private

    def resolve_token!
      token = AliExpressToken.current_token
      raise Oauth::Error, "尚未完成 OAuth 授权，请先访问 /oauth/authorize" if token.nil?

      if token.expired? && token.refresh_token.present? && !token.refresh_expired?
        token = Oauth.new.refresh!(token.refresh_token)
      elsif token.expired?
        raise Oauth::Error, "access_token 已过期，请重新授权 /oauth/authorize"
      end

      token.access_token
    end
  end
end
