# frozen_string_literal: true

module Member
  module Vault
    # I secret con la rotazione in scadenza o scaduta (CYRA-138, Fase 4 pezzo A1; copertura + età
    # CYRA-407). Da CYRA-428 non hanno più una pagina propria: quelli da cambiare sono righe della
    # lista unica di «Da sistemare» (Member::Vault::AttentionController), la copertura e i secret
    # senza regola stanno nel contesto sotto quella lista. Questo indirizzo resta e ci porta — senza
    # gate, perché un redirect non espone nulla e il permesso lo applica la destinazione.
    class RotationController < Member::BaseController
      permission_not_required "Vecchio indirizzo che rimanda alla lista unica: il permesso lo applica la " \
                              "destinazione."

      def index
        redirect_to member_vault_attention_path
      end
    end
  end
end
