# frozen_string_literal: true

module Secrets
  module Consolidation
    # Il giro MIRATO che segue un salvataggio (CYRA-777): guarda un ambiente solo e le impronte
    # toccate — quella nuova e quella che il valore aveva prima — invece dell'intera organizzazione.
    #
    # Asincrono e non in linea con la scrittura: chi salva un segreto non deve aspettare un
    # raggruppamento, e soprattutto non deve vedersi fallire il salvataggio perché una notifica non è
    # partita. Corsia `maintenance` e non `batch`: dura frazioni di secondo, e dietro i giri notturni
    # che attraversano tabelle intere aspetterebbe ore — «dopo ogni salvataggio» smetterebbe di
    # significare qualcosa.
    class RefreshJob < ApplicationJob
      queue_as :maintenance

      # Argomenti primitivi (id, non record): il job può girare molto dopo che l'oggetto è cambiato.
      # Un'organizzazione o un ambiente spariti nel frattempo non sono un errore da ritentare.
      def perform(organization_id:, environment_id: nil, fingerprints: nil)
        organization = Organizations::Organization.find_by(id: organization_id)
        return if organization.nil?

        environment = environment_id && Types::Environment.find_by(id: environment_id)
        return if environment_id.present? && environment.nil?

        Refresh.call(organization:, environment:, fingerprints:)
      end
    end
  end
end
