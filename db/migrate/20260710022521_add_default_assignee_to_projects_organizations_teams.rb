# frozen_string_literal: true

# Assegnatario di default dei ticket, configurabile a 3 livelli (progetto → team → org). Un nuovo
# ticket senza assignee esplicito eredita il default (fallback in Ticketing::CreateTicket). Colonna
# vera con FK verso accounts (non jsonb): garantisce integrità referenziale e, con on_delete: :nullify,
# sblocca la cancellazione dell'account dal pannello god (l'entità sopravvive, il default si azzera).
class AddDefaultAssigneeToProjectsOrganizationsTeams < ActiveRecord::Migration[8.1]
  def change
    add_reference :projects, :default_assignee, type: :uuid, null: true,
                  foreign_key: { to_table: :accounts, on_delete: :nullify }
    add_reference :organizations, :default_assignee, type: :uuid, null: true,
                  foreign_key: { to_table: :accounts, on_delete: :nullify }
    add_reference :teams_teams, :default_assignee, type: :uuid, null: true,
                  foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
