class CreateAccountsDeviceGrants < ActiveRecord::Migration[8.1]
  # Concessione device-flow (OAuth 2.0 Device Authorization Grant, RFC 8628). La CLI ottiene un
  # device_code + user_code, l'umano approva nel browser scegliendo l'org, la CLI fa poll fino al token.
  # account/organization sono valorizzati all'approvazione; api_token al primo poll dopo approvazione.
  def change
    create_table :accounts_device_grants, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.references :organization, type: :uuid, null: true,
                   foreign_key: { on_delete: :cascade }
      t.references :api_token, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts_api_tokens, on_delete: :nullify }

      t.string   :device_code_digest, null: false   # SHA-256 del device_code opaco (ritornato UNA volta)
      t.string   :user_code,          null: false   # "WDJB-MZHN" (display/browser)
      t.string   :client_name                        # "closeyourit-cli/x (darwin arm64)"
      t.integer  :status,   null: false, default: 0  # enum pending/approved/denied/fulfilled/expired
      t.integer  :interval, null: false, default: 5  # secondi tra i poll (RFC 8628)
      t.datetime :approved_at
      t.datetime :expires_at, null: false
      t.datetime :last_polled_at                      # per l'enforcement dello slow_down

      t.index :device_code_digest, unique: true
      t.index :user_code,          unique: true
      t.index :expires_at
    end
  end
end
