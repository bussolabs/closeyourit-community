# frozen_string_literal: true

# Discriminatore human/service su Accounts::Account. Gli account umani (default 0) fanno login
# web/password; i service account (1) sono non-umani, CLI-only (token cyi_u_ account-proxy), creati
# dall'owner per gli agenti AI. additivo, backfill implicito (default 0 = human sugli esistenti).
class AddKindToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :kind, :integer, null: false, default: 0
  end
end
