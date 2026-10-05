# frozen_string_literal: true

# CYAU-178 — l'impronta del codice che l'host aveva DAVVERO in mano al momento della consegna, letta
# dalla sua copia di lavoro con `git rev-parse HEAD`. Non è quello che l'agente dichiara a parole.
#
# Serve perché un indirizzo di proposta che punta al lavoro di un altro ticket, a una versione vecchia,
# o a un lavoro il cui ultimo invio non è mai partito, da fuori sono identici: tutti e tre passano.
# Confrontando questa sigla con quella che il servizio remoto mostra per quell'indirizzo, i tre casi si
# distinguono — e il confronto lo fa chi legge lo stato vivo della proposta, non questa colonna.
#
# NULL è legittimo e va tenuto distinto: sono tutte le consegne già registrate e tutte quelle delle
# fasi che non scrivono codice. Il vincolo di forma vale solo quando il valore c'è.
class AddObservedHeadShaToAgentsAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_attempts, :observed_head_sha, :string

    add_check_constraint :agents_attempts,
                         "observed_head_sha IS NULL OR observed_head_sha ~ '^[0-9a-f]{40}$'",
                         name: "agents_attempts_observed_head_sha_shape"
  end
end
