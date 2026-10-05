# frozen_string_literal: true

module Secrets
  module Consolidation
    # Una proposta di consolidamento (CYRA-777): «in questo ambiente, N progetti tengono lo stesso
    # valore; vuoi spostarlo nei secret dell'organizzazione?».
    #
    # È PERSISTITA e non ricalcolata a ogni pagina per due ragioni che il calcolo al volo non può
    # dare: «Non proporre più» deve restare una decisione (altrimenti la proposta rispunta al giro
    # dopo), e la notifica agli amministratori deve partire UNA volta per proposta e non a ogni giro
    # del job giornaliero.
    #
    # Non contiene MAI il valore, solo la sua impronta: una tabella di proposte non è un posto dove
    # tenere un segreto in chiaro. I progetti coinvolti e i nomi che ciascuno usa si ricavano
    # dall'impronta al momento in cui servono (Secrets::Consolidation::Candidates), così una proposta
    # non può raccontare uno stato che nel frattempo è cambiato.
    class Suggestion < ApplicationRecord
      belongs_to :organization, class_name: "Organizations::Organization"
      belongs_to :environment, class_name: "Types::Environment"
      # Valorizzato solo dopo l'accettazione: è il secret dell'organizzazione nato dalla proposta.
      belongs_to :shared_variable, class_name: "Secrets::Shared::Variable", optional: true
      belongs_to :dismissed_by, class_name: "Accounts::Account", optional: true
      belongs_to :promoted_by, class_name: "Accounts::Account", optional: true

      # open = da decidere · dismissed = «non proporre più», la proposta non torna · promoted =
      # accettata e applicata. Valori APPESI, mai riordinare.
      enum :status, { open: 0, dismissed: 1, promoted: 2 }, prefix: :status

      # L'identità è [organizzazione, ambiente, valore]: due proposte per lo stesso valore nello
      # stesso ambiente sarebbero la stessa proposta, e la seconda cancellerebbe la decisione presa
      # sulla prima.
      validates :value_fingerprint, presence: true,
                uniqueness: { scope: %i[organization_id environment_id] }
      validates :suggested_name, presence: true
      validates :projects_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validate :environment_matches_organization

      # Le proposte che toccano più progetti per prime: sono quelle che tolgono più copie a mano. A
      # parità, la più vecchia — chi guarda la lista deve vederla ferma, non riordinata a ogni giro.
      scope :ordered, -> { order(projects_count: :desc, first_seen_at: :asc) }

      private

      def environment_matches_organization
        return if environment.blank?

        errors.add(:environment, :invalid) if environment.organization_id != organization_id
      end
    end
  end
end
