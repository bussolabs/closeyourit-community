# frozen_string_literal: true

module Product
  # Colonne della matrice di un prodotto: le piattaforme ATTIVE dichiarate dai progetti del gruppo,
  # più quelle (anche disattivate) che hanno già almeno una cella compilata.
  #
  # Il secondo ramo fa due cose: permette di segnare una funzionalità su iOS PRIMA che il progetto
  # iOS esista, e impedisce che disattivare una piattaforma faccia sparire dalla vista celle già
  # scritte. Vive in un unico posto perché la regola serve sia alla matrice sia al form della cella
  # (dove decide quali platform_id sono ammissibili).
  class MatrixColumns
    def self.for(group:)
      new(group: group).call
    end

    def initialize(group:)
      @group = group
    end

    def call
      base = ::Types::Platform.where(organization_id: @group.organization_id)
      declared = ::Connections::ProjectPlatform
                 .where(project_id: ::Projects::Project.where(group_id: @group.id).select(:id))
                 .select(:platform_id)
      used = ::Connections::FeaturePlatform.where(feature_id: feature_ids).select(:platform_id)

      # `.or` esige relation strutturalmente compatibili: entrambi i rami partono da `base` senza
      # joins/includes. Un eventuale preload va aggiunto DOPO l'or, mai su un solo ramo.
      base.where(id: declared).where(active: true)
          .or(base.where(id: used))
          .ordered.to_a
    end

    private

    def feature_ids
      ::Product::Feature.joins(:category)
                        .where(product_categories: { group_id: @group.id })
                        .select(:id)
    end
  end
end
