# frozen_string_literal: true

module Integrations
  # Qual è l'organizzazione di chi gestisce l'installazione (CYRA-549).
  #
  # Serve a un solo scopo: sapere a chi restano le chiavi che oggi stanno nell'ambiente, quando il
  # passaggio alle credenziali di ciascuno viene eseguito senza che una persona indichi a mano
  # l'organizzazione.
  #
  # La risposta si ricava da un fatto già scritto nei dati, non da una variabile nuova: l'unica
  # organizzazione di cui un superadmin è PROPRIETARIO. Un superadmin che sia soltanto membro di
  # un'organizzazione non la rende sua — ci entra per lavoro, come ci entra in tutte.
  #
  # NON INDOVINA MAI. Con due candidate — o con nessuna — restituisce nil, e chi la chiama non
  # adotta niente: l'organizzazione la indica una persona, con
  # `bin/rails "integrations:adopt_system_keys[<slug>]"`. Scegliere la più vecchia, o la prima che
  # capita, vorrebbe dire consegnare la chiave dell'operatore — e il conto del suo consumo — a
  # un'organizzazione che non è la sua, che è il guasto peggiore che questa lavorazione possa fare.
  module Operator
    module_function

    def organization
      candidate = Organizations::Organization
                  .joins(memberships: :account)
                  .where(connections_memberships: { role: Connections::Membership.roles[:owner] })
                  .where(accounts: { god: true })
                  .distinct
                  .limit(2)
                  .to_a

      candidate.first if candidate.one?
    end
  end
end
