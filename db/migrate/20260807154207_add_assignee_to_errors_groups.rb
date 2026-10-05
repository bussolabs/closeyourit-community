# frozen_string_literal: true

# Assegnatario di un gruppo d'errore (CYRA-153): chi se ne fa carico, come già per i ticket. Colma
# l'asimmetria — i ticket hanno un assignee, gli errori no — così un errore può essere messo in mano
# a una persona precisa invece di restare di nessuno.
#
# Colonna vera con FK verso accounts e on_delete: :nullify (stesso pattern di default_assignee): il
# gruppo sopravvive alla cancellazione dell'account dal pannello god, l'assegnazione si azzera da sé
# invece di bloccare la delete o lasciare un id che punta al vuoto.
class AddAssigneeToErrorsGroups < ActiveRecord::Migration[8.1]
  def change
    add_reference :errors_groups, :assignee, type: :uuid, null: true,
                  foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
