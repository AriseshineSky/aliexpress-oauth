# frozen_string_literal: true

class AddAppKeyToAliExpressTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :ali_express_tokens, :app_key, :string
    add_index :ali_express_tokens, :app_key
  end
end
