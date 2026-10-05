class AddOnDeleteToAccountReferencingFks < ActiveRecord::Migration[8.1]
  # Le FK verso accounts erano tutte RESTRICT (default): un account che aveva creato/invitato/
  # impersonato qualcosa non era cancellabile dal pannello god (PG::ForeignKeyViolation/500).
  # Metadati "creato/invitato/impersonato da" (nullable) -> SET NULL (l'entita' sopravvive).
  # Eventi di impersonation (account_id/god_id NOT NULL) -> CASCADE (cadono con l'account).
  NULLIFY = [
    [ :organizations, :created_by_id ],
    [ :projects, :created_by_id ],
    [ :projects_groups, :created_by_id ],
    [ :types_platforms, :created_by_id ],
    [ :types_ticket_priorities, :created_by_id ],
    [ :types_ticket_statuses, :created_by_id ],
    [ :connections_invitations, :invited_by_id ],
    [ :accounts_sessions, :impersonated_account_id ]
  ].freeze

  CASCADE = [
    [ :accounts_impersonation_events, :account_id ],
    [ :accounts_impersonation_events, :god_id ]
  ].freeze

  def up
    NULLIFY.each { |table, column| swap_fk(table, column, on_delete: :nullify) }
    CASCADE.each { |table, column| swap_fk(table, column, on_delete: :cascade) }
  end

  def down
    (NULLIFY + CASCADE).each { |table, column| swap_fk(table, column, on_delete: nil) }
  end

  private

  def swap_fk(table, column, on_delete:)
    remove_foreign_key table, column: column
    add_foreign_key table, :accounts, column: column, on_delete: on_delete
  end
end
