# frozen_string_literal: true

module KnowledgeHelper
  # Il rendering markdown vive in MarkdownHelper (condiviso con l'analisi tecnica dei ticket):
  # le view KB continuano a chiamare `render_markdown` senza saperlo — gli helper sono inclusi tutti.

  # Colore badge per kind (mapping fisso, palette nativa — vedi rules/styling.md).
  def knowledge_kind_color(kind)
    { "note" => :sky, "decision" => :violet, "guide" => :emerald }.fetch(kind.to_s, :gray)
  end

  # Statistiche di lettura del corpo markdown per la colonna specifiche: numero di parole
  # (token non-spazio) e tempo di lettura stimato a ~200 wpm (minimo 1 minuto). Il conteggio dei
  # caratteri non sta più qui (CYRA-434): riguarda il tetto del corpo, cioè chi scrive, e vive
  # nell'editor col contatore e col limite dichiarato accanto al campo.
  def knowledge_reading_stats(body)
    words = body.to_s.scan(/\S+/).size
    { words: words, minutes: [ (words / 200.0).ceil, 1 ].max }
  end
end
