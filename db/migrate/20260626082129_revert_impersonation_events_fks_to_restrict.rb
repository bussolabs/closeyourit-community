class RevertImpersonationEventsFksToRestrict < ActiveRecord::Migration[8.1]
  # L'audit di impersonation (accounts_impersonation_events) NON deve essere distrutto alla
  # cancellazione di un account (evidence tampering). Torna da CASCADE a RESTRICT: la
  # cancellazione di un account coinvolto è bloccata e gestita da dependent: :restrict_with_error
  # (alert pulito nel pannello god), preservando sempre l'evidenza.
  COLUMNS = %i[account_id god_id].freeze

  def up
    COLUMNS.each do |column|
      remove_foreign_key :accounts_impersonation_events, column: column
      add_foreign_key :accounts_impersonation_events, :accounts, column: column
    end
  end

  def down
    COLUMNS.each do |column|
      remove_foreign_key :accounts_impersonation_events, column: column
      add_foreign_key :accounts_impersonation_events, :accounts, column: column, on_delete: :cascade
    end
  end
end
