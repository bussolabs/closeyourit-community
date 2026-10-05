# frozen_string_literal: true

# CYRA-478 — silenziare una regola rumorosa senza spegnerla. Distinto da `enabled`: una regola
# silenziata resta ATTIVA (continua a valutare e a contare), semplicemente non notifica fino a
# `muted_until`. Spegnerla è un'altra cosa e va detta con un'altra parola, altrimenti chi silenzia
# per un'ora finisce per disattivare per sempre e nessuno se ne accorge.
class AddMutedUntilToAlertingRules < ActiveRecord::Migration[8.1]
  def change
    add_column :alerting_rules, :muted_until, :datetime
  end
end
