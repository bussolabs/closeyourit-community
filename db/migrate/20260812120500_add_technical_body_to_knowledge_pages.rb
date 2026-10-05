# frozen_string_literal: true

# CYRA-429 — l'euristica "linguaggio semplice" girava a ogni lettura e l'avviso finiva davanti a chi
# legge, che non può correggerlo. Ora il verdetto è calcolato quando la pagina si salva e resta
# scritto qui: serve a chi scrive (avviso al salvataggio) e a chi cura la conoscenza di un progetto
# (quante pagine sono senza versione semplice), senza ricalcolare niente in lettura.
class AddTechnicalBodyToKnowledgePages < ActiveRecord::Migration[8.1]
  # Historical schemas do not have the current model's enums or associations.
  class Page < ActiveRecord::Base
    self.table_name = "knowledge_pages"
  end

  def up
    add_column :knowledge_pages, :technical_body, :boolean, default: false, null: false

    Page.reset_column_information
    Page.find_each do |page|
      technical = Knowledge::PlainLanguageCheck.call(text: page.body).complex?
      page.update_column(:technical_body, technical)
    end
  end

  def down
    remove_column :knowledge_pages, :technical_body
  end
end
