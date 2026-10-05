# frozen_string_literal: true

# Mappa di prodotto: la matrice funzionalità × piattaforme di un macro-progetto. Categorie e
# funzionalità sono la STRUTTURA della matrice (righe); la cella vive in Connections::FeaturePlatform
# e lo stato in Types::FeatureStatus. Prefisso tabella del namespace (rules/rails/models.md).
module Product
  def self.table_name_prefix = "product_"
end
