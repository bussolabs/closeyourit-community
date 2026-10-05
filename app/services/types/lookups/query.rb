# frozen_string_literal: true

module Types
  module Lookups
    # CYRA-738 — gli elenchi di riferimento dell'organizzazione (stati e priorità dei ticket,
    # piattaforme, ambienti, stati di una cella della matrice) serviti ai due canali a token. Nove
    # controller scrivevano la stessa identica riga: solo gli attivi, nell'ordine dell'organizzazione.
    class Query < ApplicationService
      # Gli elenchi che i due canali servono. Il nome lo sceglie il controller, mai chi chiama da
      # fuori: la lista chiusa evita che un giorno arrivi qui il nome di un'associazione qualunque.
      COLLECTIONS = %i[environments platforms ticket_priorities ticket_statuses feature_statuses].freeze

      def initialize(organization:, collection:)
        @organization = organization
        @collection = collection.to_sym
      end

      def call
        # Nome fuori elenco = errore di scrittura del codice, non input dell'utente: si ferma subito
        # invece di tornare una lista vuota che sembrerebbe un'organizzazione senza dati.
        raise ArgumentError, "elenco di riferimento non previsto: #{@collection}" unless
          COLLECTIONS.include?(@collection)

        @organization.public_send(@collection).active.ordered
      end
    end
  end
end
