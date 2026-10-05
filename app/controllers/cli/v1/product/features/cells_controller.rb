# frozen_string_literal: true

module Cli
  module V1
    module Product
      module Features
        # Una cella della matrice: l'incrocio [funzionalità, piattaforma]. Non ha id proprio, quindi
        # la piattaforma È il parametro del path. PUT è un upsert (Product::Cells::Set), DELETE
        # azzera (Product::Cells::Clear, idempotente).
        #
        # Il web separa "nuova cella" da "modifica cella" perché sono due form diversi; qui la
        # distinzione non serve e la regola si unifica in find_platform!: la piattaforma dev'essere
        # una colonna della matrice oppure una piattaforma attiva dell'org.
        #
        # Stato e versione si accettano per NOME (code / version) oltre che per UUID, ma non si
        # passano al service così come arrivano: si cercano dentro l'insieme ammissibile (stati
        # attivi dell'org, release del prodotto che girano su quella piattaforma). Un riferimento
        # estraneo semplicemente non viene trovato → 404 di dominio, mai una scrittura sbagliata; il
        # service ricontrolla comunque gli id, e il model dietro di lui.
        #
        # Model SEMPRE fully-qualified (`::Product::…`) — vedi BaseController.
        class CellsController < Cli::V1::Product::BaseController
          before_action :set_matrix_group!
          before_action :require_product_management
          before_action :set_feature_and_platform

          def update
            result = ::Product::Cells::Set.call(feature: @feature, platform: @platform,
                                                status_id: resolved_status_id, release_id: resolved_release_id,
                                                actor: Current.account)
            if result.ok?
              render_ok(FeatureCellSerializer.new(result.value))
            else
              render_error(result.error.code, result.error.message,
                           status: result.error.status, details: result.error.details)
            end
          end

          def destroy
            ::Product::Cells::Clear.call(feature: @feature, platform: @platform)
            render_no_content
          end

          private

          def set_feature_and_platform
            @feature = find_feature!(params[:feature_id])
            @platform = find_platform!(params[:platform_id])
            @cell = ::Connections::FeaturePlatform.find_by(feature_id: @feature.id, platform_id: @platform.id)
          end

          # Solo gli stati ATTIVI dell'org: uno stato disattivato è uscito dalle scelte possibili.
          # Un code sconosciuto (o di un'altra org) non si trova → il service risponde R404-PRODUCT-001.
          def resolved_status_id
            ref = params[:status].to_s.strip.downcase
            statuses = ::Types::FeatureStatus.where(organization_id: Current.organization.id).active
            (statuses.find_by(id: ref) || statuses.find_by(code: ref))&.id
          end

          # La versione si cerca fra i candidati della cella (release dei progetti del prodotto che
          # girano su quella piattaforma), con `selected` = quella già indicata: ri-salvare una cella
          # senza toccarne la versione non deve diventare un errore quando il limite dei candidati
          # la taglierebbe fuori. Un riferimento non ammissibile resta valorizzato ma irrisolto, così
          # il service risponde 404 invece di scrivere la cella senza versione (silenzioso).
          def resolved_release_id
            ref = params[:release].to_s.strip
            return nil if ref.blank?

            candidate = ::Product::ReleaseCandidates
                        .for(group: @group, platform: @platform, selected: @cell&.release)
                        .find { |release| release.id == ref || release.version.casecmp?(ref) }
            candidate&.id || ref
          end
        end
      end
    end
  end
end
