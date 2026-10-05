# frozen_string_literal: true

# Funzionalità della matrice (riga: "2FA", "Apple login"). `category_name` viaggia insieme all'id
# perché da terminale la funzionalità si referenzia come "Categoria/Nome": senza, chi legge un
# elenco non saprebbe come richiamarla senza una seconda chiamata.
class FeatureSerializer < ApplicationSerializer
  attributes :id, :name, :description, :position, :category_id, :knowledge_page_id

  attribute :category_name do |feature|
    feature.category&.name
  end
end
