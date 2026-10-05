# frozen_string_literal: true

module Cli
  module V1
    module Product
      # Base dei controller della matrice funzionalità × piattaforme sul canale CLI. Concentra la
      # risoluzione degli identificatori e i due gate, perché è lì che vive l'anti-BOLA: tutto si
      # cerca DENTRO il prodotto del path, che a sua volta si cerca dentro i gruppi visibili. Un
      # riferimento fuori scope non viene trovato → RecordNotFound → R404, mai un 403 che
      # confermerebbe l'esistenza della risorsa.
      #
      # ATTENZIONE alla risoluzione delle costanti: dentro Cli::V1::Product::* il costante
      # `Product::Feature` risolve in questo namespace (NameError a runtime, non a boot). I model di
      # dominio vanno SEMPRE scritti fully-qualified con `::`, come in Member::Product::*.
      class BaseController < Cli::V1::BaseController
        private

        # Il prodotto (Projects::Group) è sempre nel path. visible_groups e non org.groups: la
        # matrice è contenuto redazionale, chi non è assegnato al prodotto non ne vede la mappa.
        def set_matrix_group!
          @group = visible_groups.find(params[:matrix_id] || params[:id])
        end

        # Categoria per UUID o per nome: dentro un prodotto il nome è unico (validazione su
        # [group_id, name]), quindi non c'è ambiguità da sciogliere.
        def find_category!(ref)
          ref = ref.to_s.strip
          raise ActiveRecord::RecordNotFound if ref.blank?

          scope = ::Product::Category.where(group_id: @group.id)
          category = scope.find_by(id: ref) || scope.find_by("LOWER(name) = ?", ref.downcase)
          raise ActiveRecord::RecordNotFound if category.nil?

          category
        end

        # Funzionalità per UUID oppure "Categoria/Nome". Il nome da solo NON basta: è unico per
        # categoria, non per prodotto, e accettarlo significherebbe scrivere su una riga a caso fra
        # le omonime. Con la categoria davanti il riferimento è esatto e resta leggibile.
        def find_feature!(ref)
          ref = ref.to_s.strip
          scope = ::Product::Feature.joins(:category).where(product_categories: { group_id: @group.id })
          feature = scope.find_by(id: ref) || find_feature_by_path(scope, ref)
          raise ActiveRecord::RecordNotFound if feature.nil?

          feature
        end

        # Piattaforma per UUID o code. Ammesse: le colonne della matrice (comprese le disattivate che
        # hanno già celle — non si nasconde quel che è già scritto) e le piattaforme ATTIVE dell'org,
        # che aprono una colonna nuova (segnare una funzionalità su iOS prima che il progetto iOS
        # esista). Una piattaforma disattivata senza celle resta fuori: il canale Member vieta già di
        # creare celle nuove su una piattaforma dismessa.
        def find_platform!(ref)
          ref = ref.to_s.strip.downcase
          platform = assignable_platforms.find do |candidate|
            candidate.id == ref || candidate.code.downcase == ref
          end
          raise ActiveRecord::RecordNotFound if platform.nil?

          platform
        end

        def assignable_platforms
          @assignable_platforms ||=
            (::Product::MatrixColumns.for(group: @group) + Current.organization.platforms.active.ordered.to_a).uniq
        end

        # Lettura: gata da product_features.view; chi gestisce vede sempre (specchio del web).
        def require_product_view
          require_permission!("product_features.view") unless authorization.can?("product_features.manage")
        end

        def require_product_management
          require_permission!("product_features.manage")
        end

        def find_feature_by_path(scope, ref)
          category_name, _, feature_name = ref.rpartition("/")
          return nil if category_name.blank? || feature_name.blank?

          scope.where(product_categories: { group_id: @group.id })
               .where("LOWER(product_categories.name) = ?", category_name.strip.downcase)
               .find_by("LOWER(product_features.name) = ?", feature_name.strip.downcase)
        end
      end
    end
  end
end
