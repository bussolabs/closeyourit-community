class ChangeTicketingEventsActorFksToNullify < ActiveRecord::Migration[8.1]
  # actor/true_actor con FK RESTRICT (default) rendevano un account NON cancellabile appena
  # aveva agito su un ticket (PG::ForeignKeyViolation alla destroy dal pannello god) e
  # contraddicevano l'intento "snapshot resiste a cancellazione". Passaggio a ON DELETE SET NULL:
  # l'account si cancella, l'evento resta, actor/true_actor → NULL, actor_name conserva chi era.
  def up
    remove_foreign_key :ticketing_events, column: :actor_id
    remove_foreign_key :ticketing_events, column: :true_actor_id
    add_foreign_key :ticketing_events, :accounts, column: :actor_id, on_delete: :nullify
    add_foreign_key :ticketing_events, :accounts, column: :true_actor_id, on_delete: :nullify
  end

  def down
    remove_foreign_key :ticketing_events, column: :actor_id
    remove_foreign_key :ticketing_events, column: :true_actor_id
    add_foreign_key :ticketing_events, :accounts, column: :actor_id
    add_foreign_key :ticketing_events, :accounts, column: :true_actor_id
  end
end
