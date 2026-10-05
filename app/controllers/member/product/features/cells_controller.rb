# frozen_string_literal: true

module Member
  module Product
    module Features
      # Una cella della matrice: l'incrocio [funzionalità, piattaforma]. Non ha id proprio — la
      # piattaforma È il parametro. La edit rende un turbo frame che rimpiazza la cella in pagina;
      # senza JS (rack_test, e i system spec) la stessa view è una pagina completa.
      #
      # new/create esistono per il caso "prima colonna": segnare una funzionalità su una piattaforma
      # che la matrice non mostra ancora (nessun progetto la dichiara e nessuna cella la usa). Lì la
      # piattaforma la sceglie il form, e scrivendo la cella la colonna compare da sola.
      #
      # `edit` è già gestione: apre il form di scrittura e carica le versioni indicabili, quindi è
      # gated da product_features.manage come tutto il resto.
      class CellsController < Member::BaseController
        before_action :require_management
        before_action :set_feature
        before_action :set_platform, only: %i[edit update destroy]
        # Solo le action che RENDONO un form: update/create rispondono sempre con un redirect.
        before_action :set_form_data, only: %i[new edit]

        def new
          @assignable = assignable_platforms
          @platform = @assignable.first
        end

        def create
          @platform = assignable_platforms.find { |platform| platform.id == params[:platform_id] }
          raise ActiveRecord::RecordNotFound if @platform.nil?

          save_cell
        end

        def edit
          # @cell arriva da set_platform (che la usa per decidere se la casella è apribile).
          # Le versioni si caricano SOLO qui: metterle nella matrice sarebbe una query per colonna.
          # `selected`: quella già indicata resta in elenco anche se il limite la taglierebbe fuori.
          @releases = release_candidates(@platform, selected: @cell&.release)
        end

        def update
          save_cell
        end

        def destroy
          ::Product::Cells::Clear.call(feature: @feature, platform: @platform)
          redirect_to member_product_matrix_path(@group), notice: t("member.product.cells.cleared")
        end

        private

        def save_cell
          result = ::Product::Cells::Set.call(feature: @feature, platform: @platform,
                                              status_id: params[:status_id], release_id: params[:release_id],
                                              actor: Current.account)
          if result.ok?
            redirect_to member_product_matrix_path(@group), notice: t("member.product.cells.updated")
          else
            redirect_to member_product_matrix_path(@group), alert: result.error.message
          end
        end

        # Anti-BOLA: la funzionalità si cerca dentro i prodotti visibili → 404, mai 403.
        def set_feature
          @feature = ::Product::Feature.joins(:category)
                                       .where(product_categories: { group_id: visible.groups.select(:id) })
                                       .find(params[:feature_id])
          @group = @feature.category.group
        end

        # Per modificare o azzerare, la piattaforma deve essere una colonna REALE della matrice:
        # un platform_id arbitrario → 404, mai 403.
        #
        # Una piattaforma disattivata resta colonna finché ha celle (per non nascondere quel che è
        # già scritto), ma lì si può solo correggere l'esistente: su una casella ancora vuota si
        # aprirebbe la porta a celle nuove su una piattaforma dismessa, che il flusso "segna su
        # un'altra piattaforma" vieta già.
        def set_platform
          @platform = matrix_columns.find { |platform| platform.id == params[:platform_id] }
          raise ActiveRecord::RecordNotFound if @platform.nil?

          @cell = ::Connections::FeaturePlatform.find_by(feature_id: @feature.id, platform_id: @platform.id)
          raise ActiveRecord::RecordNotFound if @cell.nil? && !@platform.active?
        end

        def set_form_data
          @statuses = Current.organization.feature_statuses.active.ordered.to_a
        end

        def matrix_columns
          @matrix_columns ||= ::Product::MatrixColumns.for(group: @group)
        end

        # Piattaforme su cui questa funzionalità può ancora essere segnata: le attive dell'org che
        # non hanno già una cella per lei (quelle ce l'hanno si modificano dalla matrice).
        def assignable_platforms
          taken = ::Connections::FeaturePlatform.where(feature_id: @feature.id).pluck(:platform_id)
          Current.organization.platforms.active.ordered.reject { |platform| taken.include?(platform.id) }
        end

        def release_candidates(platform, selected: nil)
          ::Product::ReleaseCandidates.for(group: @group, platform: platform, selected: selected)
        end

        def require_management
          require_permission!("product_features.manage")
        end
      end
    end
  end
end
