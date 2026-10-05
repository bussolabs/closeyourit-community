# frozen_string_literal: true

module KnowledgeAttachmentsHelper
  # Icona per tipo. Gli script hanno un'icona propria: chi guarda la card deve distinguere a colpo
  # d'occhio un file di testo da uno eseguibile-in-teoria, dato che qui convivono.
  ATTACHMENT_ICONS = {
    "application/pdf" => "file-text",
    "application/zip" => "file-archive",
    "application/x-tar" => "file-archive",
    "application/gzip" => "file-archive",
    "text/csv" => "file-spreadsheet",
    "text/markdown" => "file-text",
    "text/plain" => "file-text"
  }.freeze

  def knowledge_attachment_icon(content_type)
    return "file-image" if content_type.to_s.start_with?("image/")
    return "file-code" if knowledge_attachment_script?(content_type)

    ATTACHMENT_ICONS[content_type] || "file"
  end

  # Vero per i tipi che l'utente riconosce come "script/codice". Governa il badge che dichiara
  # esplicitamente che il file è solo conservato: senza, un utente potrebbe ragionevolmente pensare
  # che caricare uno script su una pagina di procedura serva a farlo eseguire da qualcuno.
  def knowledge_attachment_script?(content_type)
    Knowledge::Constants::SCRIPT_CONTENT_TYPES.include?(content_type.to_s)
  end
end
