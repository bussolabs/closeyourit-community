# frozen_string_literal: true

module Member
  module Vault
    # Pagina «Cosa puoi fare qui» (CYRA-430). Diverse funzioni del Vault esistevano ma non si vedevano:
    # la sincronizzazione con il sistema del codice, i comandi per leggere i segreti dal proprio
    # computer, lo sblocco della riga per modificarla, lo storico con ripristino, i segreti che
    # richiedono una seconda approvazione e il fatto che ogni lettura resti registrata. Alcune vivevano
    # solo dentro un'etichetta che compare al passaggio del mouse: chi non le trovava continuava a
    # copiare i valori a mano, cioè proprio ciò che il prodotto vuole evitare.
    #
    # Nessun gate: la pagina RACCONTA le funzioni, non ne espone i valori. Dove porta il collegamento di
    # ciascuna dipende invece dai permessi (Member::VaultHelper#vault_capability_link), così non si offre
    # mai la porta di una stanza chiusa.
    class CapabilitiesController < Member::BaseController
      permission_not_required "Racconta cosa si può fare nella cassaforte: non mostra nessun valore."

      # L'ordine è quello della pagina: prima le due cose che si fanno ogni giorno (leggere da riga di
      # comando, sincronizzare), poi i gesti dentro la matrice, infine le due garanzie.
      FEATURES = %i[cli_read github_sync personal_direnv unlock_row history_rollback four_eyes
                    read_audit].freeze

      def index
        @features = FEATURES
      end
    end
  end
end
