# frozen_string_literal: true

# Interruttore del revisore automatico delle pagine di conoscenza (CYRA-764).
#
# Chiave propria e non riuso di `ai_embeddings_enabled`, benché parlino con lo stesso server di casa:
# spegnere il revisore vuol dire «le pagine entrano senza controllo», spegnere gli embedding vuol dire
# «la ricerca degrada a testo». Sono due decisioni diverse, prese in momenti diversi.
#
# Default FALSE, al contrario delle altre chiavi: il gate è fail-closed, e finché CHAT_API_KEY non è
# nel vault ogni salvataggio di pagina risponderebbe 503. Un rilascio non deve poter rompere la
# knowledge da solo: il god accende l'interruttore da Valhalla dopo aver messo la chiave.
class AddAiKnowledgeReviewSwitch < ActiveRecord::Migration[8.1]
  def change
    add_column :settings_global, :ai_knowledge_review_enabled, :boolean, null: false, default: false
  end
end
