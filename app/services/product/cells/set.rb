# frozen_string_literal: true

module Product
  module Cells
    # Scrive una cella della matrice: stato e (facoltativa) versione da cui la funzionalità è
    # disponibile. Upsert sull'identità [funzionalità, piattaforma].
    #
    # Stato e release NON si prendono per id grezzo: si cercano dentro l'insieme ammissibile (stati
    # attivi dell'org, release del prodotto che girano su quella piattaforma). Un id estraneo
    # semplicemente non viene trovato → 404 di dominio, mai una scrittura sbagliata. È la stessa
    # difesa per costruzione di Member::ProjectSecretsController#promote; il model ricontrolla.
    class Set < ApplicationService
      def initialize(feature:, platform:, status_id:, actor:, release_id: nil)
        @feature = feature
        @platform = platform
        @status_id = status_id
        @release_id = release_id.presence
        @actor = actor
      end

      def call
        status = allowed_statuses.find_by(id: @status_id)
        return not_found(:status) if status.nil?

        cell = ::Connections::FeaturePlatform.find_or_initialize_by(feature: @feature, platform: @platform)
        # La versione già indicata resta ammissibile anche se il limite dei candidati la taglierebbe
        # fuori: ri-salvare una cella senza toccarne la versione non deve diventare un errore.
        release = resolve_release(selected: cell.release)
        return not_found(:release) if @release_id.present? && release.nil?

        cell.created_by ||= @actor
        # La versione segue lo stato: riportando una funzionalità a "pianificata" o "in lavorazione"
        # la versione da cui era disponibile non vale più, e resterebbe attaccata a una cella che
        # non dice più "è nelle mani degli utenti".
        cell.assign_attributes(status: status, release: status.released? ? release : nil)

        return Result.ok(cell) if cell.save

        Result.err(AppError.new(cell.errors.full_messages.to_sentence,
                                code: "R422-PRODUCT-003", details: cell.errors.to_hash))
      end

      private

      # Solo gli stati attivi: uno stato disattivato è uscito dalle scelte possibili (il model lo
      # rifiuta comunque alla creazione, qui non compare proprio tra i candidati).
      def allowed_statuses
        ::Types::FeatureStatus.where(organization_id: @feature.organization_id).active
      end

      def resolve_release(selected: nil)
        return nil if @release_id.blank?

        ::Product::ReleaseCandidates
          .for(group: @feature.category.group, platform: @platform, selected: selected)
          .find { |candidate| candidate.id == @release_id }
      end

      def not_found(field)
        Result.err(AppError.new(I18n.t("member.product.cells.errors.#{field}_not_found"),
                                code: "R404-PRODUCT-001", status: :not_found))
      end
    end
  end
end
