# frozen_string_literal: true

# Handle globale dell'account (per le @menzioni nei commenti). Derivato dalla parte locale dell'email,
# normalizzato a [a-z0-9_] e reso unico. NOT NULL + unique DOPO il backfill dei record esistenti.
class AddHandleToAccounts < ActiveRecord::Migration[8.1]
  # Modello throwaway: backfill senza i callback/validazioni del modello reale (che ora genera l'handle).
  class MigrationAccount < ActiveRecord::Base
    self.table_name = "accounts"
  end

  def up
    add_column :accounts, :handle, :string

    taken = []
    MigrationAccount.reset_column_information
    MigrationAccount.order(:created_at).each do |account|
      handle = unique_handle(account.email, taken)
      taken << handle
      account.update_columns(handle: handle) # rubocop:disable Rails/SkipsModelValidations
    end

    change_column_null :accounts, :handle, false
    add_index :accounts, :handle, unique: true
  end

  def down
    remove_column :accounts, :handle
  end

  private

  # Parte locale dell'email → [a-z0-9_], deduplicata con suffisso numerico crescente.
  def unique_handle(email, taken)
    base = email.to_s.split("@").first.to_s.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "")
    base = "user" if base.blank?
    candidate = base
    n = 0
    while taken.include?(candidate) || MigrationAccount.where(handle: candidate).exists?
      n += 1
      candidate = "#{base}#{n}"
    end
    candidate
  end
end
