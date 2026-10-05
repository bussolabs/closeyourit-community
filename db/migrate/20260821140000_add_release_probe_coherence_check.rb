# frozen_string_literal: true

# CYRA-605 — dichiarare «il rilascio in produzione è in piedi» su un progetto che non ha detto quale
# sia il suo ambiente di produzione sarebbe una prova che nessuno potrà mai vedere: senza quel
# collegamento il sistema non registra nessun rilascio vivo, e la lavorazione resterebbe ferma ad
# aspettare finché non chiama una persona. Meglio impedirlo adesso, mentre la scelta si sta facendo,
# che scoprirlo fra un mese su ogni ticket.
#
# Il vincolo sta nel DATABASE e non solo nel modello perché qui si scrive anche con `update_column`,
# che le validazioni le salta: il canale che sincronizza i repository da GitHub aggiorna colonne
# senza passare dal modello, e una riga incoerente scritta da lì nessuno la vedrebbe mai.
class AddReleaseProbeCoherenceCheck < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :github_repositories,
                         "release_probe <> 0 OR production_environment_id IS NOT NULL",
                         name: "github_repositories_deploy_smoke_needs_production"
  end
end
