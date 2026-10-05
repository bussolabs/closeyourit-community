# frozen_string_literal: true

module Secrets
  module Consolidation
    # Il giro giornaliero sulle proposte di «valore in comune» (CYRA-777): per ogni organizzazione
    # ricalcola i gruppi e allinea la tabella delle proposte. Serve anche quando nessuno tocca niente
    # — una proposta smette di essere vera perché qualcuno ha ruotato uno dei due valori, e questo è
    # il solo posto che se ne accorge.
    #
    # Org-wide, nessuno scoping di visibilità: è un giro di sistema. Chi riceve la notifica lo decide
    # il dispatch, per organizzazione.
    class ScanJob < ApplicationJob
      queue_as :batch

      def perform
        Organizations::Organization.find_each do |organization|
          Refresh.call(organization: organization)
        end
      end
    end
  end
end
