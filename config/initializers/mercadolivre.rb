# frozen_string_literal: true

module MercadoLivre
  DEFAULT_SITE = "MLB"

  # ML 授权端点按国家/站点区分（token 端点 api.mercadolibre.com 全球统一，不在此表）。
  # 官方列表：https://developers.mercadolivre.com.br/pt_br/autenticacao-e-autorizacao
  SITES = {
    "MLB" => "https://auth.mercadolivre.com.br/authorization", # 巴西 Brasil
    "MLM" => "https://auth.mercadolibre.com.mx/authorization", # 墨西哥 México
    "MLA" => "https://auth.mercadolibre.com.ar/authorization", # 阿根廷 Argentina
    "MLC" => "https://auth.mercadolibre.cl/authorization",     # 智利 Chile
    "MCO" => "https://auth.mercadolibre.com.co/authorization", # 哥伦比亚 Colombia
    "MPE" => "https://auth.mercadolibre.com.pe/authorization", # 秘鲁 Perú
    "MLU" => "https://auth.mercadolibre.com.uy/authorization", # 乌拉圭 Uruguay
    "MPT" => "https://auth.mercadolibre.com.pt/authorization", # 葡萄牙 Portugal
    "MBO" => "https://auth.mercadolibre.com.bo/authorization", # 玻利维亚 Bolivia
    "MCR" => "https://auth.mercadolibre.co.cr/authorization",  # 哥斯达黎加 Costa Rica
    "MRD" => "https://auth.mercadolibre.com.do/authorization", # 多米尼加 RD
    "MEC" => "https://auth.mercadolibre.com.ec/authorization", # 厄瓜多尔 Ecuador
    "MGT" => "https://auth.mercadolibre.com.gt/authorization", # 危地马拉 Guatemala
    "MHN" => "https://auth.mercadolibre.com.hn/authorization", # 洪都拉斯 Honduras
    "MNI" => "https://auth.mercadolibre.com.ni/authorization", # 尼加拉瓜 Nicaragua
    "MPA" => "https://auth.mercadolibre.com.pa/authorization", # 巴拿马 Panamá
    "MPY" => "https://auth.mercadolibre.com.py/authorization", # 巴拉圭 Paraguay
    "MSV" => "https://auth.mercadolibre.com.sv/authorization", # 萨尔瓦多 El Salvador
    "MLV" => "https://auth.mercadolibre.com.ve/authorization"  # 委内瑞拉 Venezuela
  }.freeze

  SITE_NAMES = {
    "MLB" => "巴西 MLB",
    "MLM" => "墨西哥 MLM",
    "MLA" => "阿根廷 MLA",
    "MLC" => "智利 MLC",
    "MCO" => "哥伦比亚 MCO",
    "MPE" => "秘鲁 MPE",
    "MLU" => "乌拉圭 MLU",
    "MPT" => "葡萄牙 MPT",
    "MBO" => "玻利维亚 MBO",
    "MCR" => "哥斯达黎加 MCR",
    "MRD" => "多米尼加 MRD",
    "MEC" => "厄瓜多尔 MEC",
    "MGT" => "危地马拉 MGT",
    "MHN" => "洪都拉斯 MHN",
    "MNI" => "尼加拉瓜 MNI",
    "MPA" => "巴拿马 MPA",
    "MPY" => "巴拉圭 MPY",
    "MSV" => "萨尔瓦多 MSV",
    "MLV" => "委内瑞拉 MLV"
  }.freeze

  App = Struct.new(:app_key, :app_secret, :label, :primary, :source, :site, keyword_init: true) do
    def primary?
      primary
    end

    def redis?
      source == :redis
    end

    def env?
      source == :env
    end

    def display_name
      label.presence || app_key
    end

    # 站点 ID（MLB / MLM / …）；未指定时回退 DEFAULT_SITE。
    def site_id
      site.presence || MercadoLivre::DEFAULT_SITE
    end

    def site_display
      MercadoLivre.site_display(site_id)
    end
  end

  class << self
    def config
      @config ||= ActiveSupport::OrderedOptions.new.tap do |c|
        c.app_key = ENV.fetch("MERCADOLIVRE_APP_KEY", "")
        c.app_secret = ENV.fetch("MERCADOLIVRE_APP_SECRET", "")
        c.callback_url = ENV.fetch("MERCADOLIVRE_CALLBACK_URL", default_callback_url)
        # 可转发授权链接用的 Redirect URI：必须是 DevCenter 已注册的 HTTPS 地址（
        # 默认取生产 callback；本地若配了 localhost 则退回文档中的生产地址）。
        c.share_callback_url = ENV.fetch("MERCADOLIVRE_SHARE_CALLBACK_URL", default_share_callback_url)
        c.authorize_url = ENV.fetch("MERCADOLIVRE_AUTHORIZE_URL", "")
        c.api_base = ENV.fetch("MERCADOLIVRE_API_BASE", "https://api.mercadolibre.com")
      end
    end

    def configured?
      apps.any?
    end

    # Env apps (optional bootstrap) + Redis registry. Each ML app has its own
    # token under mercadolivre:oauth:token:{app_key}, so one shared Redirect
    # URI is safe across multiple Client IDs.
    def apps
      build_apps
    end

    def find_app(app_key)
      key = app_key.to_s.strip
      apps.find { |a| a.app_key == key }
    end

    def primary_app
      apps.find(&:primary?) || apps.first
    end

    def reset_apps!
      # Kept for callers after registry writes; apps are rebuilt each request.
      nil
    end

    # 站点授权地址：已知站点（SITES 表）永远走自己的国家端点，保证 MLB / MLM 等共存互不影响；
    # MERCADOLIVRE_AUTHORIZE_URL 仅供自定义/未知站点兜底（default 时与巴西同源，行为不变）。
    def authorize_url_for(site)
      site_id = normalize_site(site)
      SITES[site_id] || config.authorize_url.to_s.strip.presence || SITES[DEFAULT_SITE]
    end

    # 纯展示用，如 "墨西哥 MLM"；未知站点回退巴西。
    def site_display(site)
      SITE_NAMES.fetch(normalize_site(site), SITES.keys.join("/"))
    end

    # 站点规范化：空 → DEFAULT_SITE；strict 时未知值抛错（用于表单写入校验），
    # 非 strict 回退默认（用于读取已有 Redis 数据，避免旧数据/脏数据打挂首页）。
    def normalize_site(site, strict: false)
      value = site.to_s.strip.upcase
      value = DEFAULT_SITE if value.blank?
      return value if SITES.key?(value)

      if strict
        raise ArgumentError, "未知站点 #{site.inspect}，可选：#{SITES.keys.join(' / ')}"
      end
      DEFAULT_SITE
    end

    private

    SHARE_CALLBACK_DEFAULT = "https://aliexpress-oauth.onrender.com/ml/callback"

    # Production deploy safety net: if MERCADOLIVRE_CALLBACK_URL is missing
    # (e.g. set via Render dashboard after first deploy), derive it from APP_HOST
    # so the token exchange never uses the http://localhost fallback.
    def default_callback_url
      host = ENV["APP_HOST"].to_s.strip
      if Rails.env.production? && host.present? && !host.include?("http")
        "https://#{host}/ml/callback"
      else
        "http://localhost:3000/ml/callback"
      end
    end

    def default_share_callback_url
      registered = ENV["MERCADOLIVRE_CALLBACK_URL"].to_s
      return registered if registered.start_with?("https://") && !registered.include?("localhost")

      SHARE_CALLBACK_DEFAULT
    end

    def build_apps
      list = []
      seen = {}

      add = lambda do |key, secret, label:, primary: false, source:, site: nil|
        key = key.to_s.strip
        secret = secret.to_s.strip
        return if key.blank? || secret.blank?
        return if key.start_with?("your_") || secret.start_with?("your_")
        return if seen[key]

        seen[key] = true
        list << App.new(
          app_key: key,
          app_secret: secret,
          label: label,
          primary: primary,
          site: normalize_site(site),
          source: source
        )
      end

      # Optional env bootstrap (merged with Redis; Redis wins — it can self-serve via console).
      add.call(
        config.app_key,
        config.app_secret,
        label: ENV.fetch("MERCADOLIVRE_APP_LABEL", "primary"),
        primary: true,
        site: ENV["MERCADOLIVRE_SITE"],
        source: :env
      )

      # Preferred: apps registered in Redis via the console
      MercadoLivre::AppRegistry.all.each do |entry|
        add.call(
          entry.app_key,
          entry.app_secret,
          label: entry.label.presence || entry.app_key,
          primary: list.empty?,
          site: entry.site,
          source: :redis
        )
      end

      list
    rescue JSON::ParserError, Redis::BaseError => e
      Rails.logger.warn("[MercadoLivre] registry load failed: #{e.message}")
      list
    end
  end
end
