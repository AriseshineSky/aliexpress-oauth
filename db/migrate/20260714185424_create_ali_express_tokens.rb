class CreateAliExpressTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :ali_express_tokens do |t|
      t.text :access_token
      t.text :refresh_token
      t.datetime :expires_at
      t.datetime :refresh_expires_at
      t.string :account
      t.string :user_id
      t.json :raw_response

      t.timestamps
    end
  end
end
