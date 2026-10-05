# frozen_string_literal: true

# CYRA-598 — distinguere CHI ha fermato la lavorazione.
#
# Finora `blocked_at` diceva solo che era ferma. Chi la guardava leggeva sempre la stessa frase, che
# nomina la revisione e conta le bocciature. Con un blocco dichiarato dalla macchina quel conteggio e
# zero, e la frase diventerebbe «La revisione ha respinto autopilot 0 volte di fila»: falsa, e nel
# posto peggiore, perche' e' l'unica cosa che chi deve decidere legge.
#
# `unreachable_count` conta SOLO le consegne che dichiarano di non essere riuscite a guardare. Non
# poteva essere il conteggio dei tentativi bocciati: una consegna «non sono riuscito a leggere» e' un
# tentativo APPROVATO — il formato e' valido, il contenuto e' onesto — quindi non ne bocciata nessuna
# e il tetto esistente non la vedrebbe mai.
class AddBlockedKindToAgentsWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_workflows, :blocked_kind, :string
    add_column :agents_workflows, :unreachable_count, :integer, null: false, default: 0

    # Le lavorazioni gia' ferme oggi lo sono per il tetto dei tentativi: era l'unico modo di fermarsi.
    # Senza questo, una lavorazione ferma da prima leggerebbe blocked_kind nil e cadrebbe nel ramo
    # nuovo, che le stamperebbe accanto il motivo di un agente che non ha mai parlato.
    up_only do
      execute <<~SQL.squish
        UPDATE agents_workflows SET blocked_kind = 'attempt_limit' WHERE blocked_at IS NOT NULL
      SQL
    end

    add_check_constraint :agents_workflows,
                         "blocked_kind IS NULL OR blocked_kind IN ('attempt_limit', 'agent_blocked')",
                         name: "agents_workflows_blocked_kind_valido"
    # Un blocco senza chi l'ha scritto e' il caso che rimette in piedi la frase falsa.
    add_check_constraint :agents_workflows,
                         "blocked_at IS NULL OR blocked_kind IS NOT NULL",
                         name: "agents_workflows_blocco_ha_un_autore"
  end
end
