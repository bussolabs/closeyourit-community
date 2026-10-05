# frozen_string_literal: true

# CYRA-697 — chi ha pubblicato su internet la dashboard di traffico. Prima non lo sapeva nessuno: il
# link nasceva senza autore e la domanda «chi è stato» non aveva risposta nel prodotto.
# `on_delete: :nullify` come per i canali di avviso: cancellare la persona non deve portarsi via il
# link, che resta pubblico finché qualcuno non lo revoca.
class AddCreatedByToAnalyticsLinks < ActiveRecord::Migration[8.1]
  def change
    add_reference :analytics_links, :created_by, type: :uuid, null: true, index: true,
                                                 foreign_key: { to_table: :accounts, on_delete: :nullify }
  end
end
