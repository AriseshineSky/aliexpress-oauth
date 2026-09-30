# frozen_string_literal: true

module MercadoLivre
  # PKCE (RFC 7636) helpers — Mercado Livre requires code_verifier on the token
  # exchange for apps with PKCE enabled.
  #   verifier  = generate_verifier            # 43 chars, [A-Za-z0-9-._~]
  #   challenge = challenge_for(verifier)      # S256 base64url, no padding
  class Pkce
    class << self
      def generate_verifier
        SecureRandom.urlsafe_base64(48) # 64 chars, URL-safe
      end

      def challenge_for(verifier)
        verifier = verifier.to_s
        raise ArgumentError, "PKCE code_verifier 不能为空" if verifier.blank?

        Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      end
    end
  end
end
