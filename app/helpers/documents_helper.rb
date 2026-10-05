# frozen_string_literal: true

module DocumentsHelper
  DOCUMENT_TYPE_LABELS = {
    "application/pdf" => "PDF",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "Word",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "Excel",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" => "PowerPoint",
    "application/vnd.oasis.opendocument.text" => "Writer",
    "application/vnd.oasis.opendocument.spreadsheet" => "Calc",
    "application/vnd.oasis.opendocument.presentation" => "Impress",
    "text/plain" => "Text",
    "text/csv" => "CSV",
    "text/markdown" => "Markdown",
    "application/zip" => "Zip"
  }.freeze

  # Lucide name and colour class per type. Literal classes, so the Tailwind scanner sees every colour. CYRA-883
  DOCUMENT_TYPE_ICONS = {
    "application/pdf" => [ "file-text", "text-red-500 dark:text-red-400" ],
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => [ "file-type", "text-blue-600 dark:text-blue-400" ],
    "application/vnd.oasis.opendocument.text" => [ "file-type", "text-blue-600 dark:text-blue-400" ],
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => [ "file-spreadsheet", "text-emerald-600 dark:text-emerald-400" ],
    "application/vnd.oasis.opendocument.spreadsheet" => [ "file-spreadsheet", "text-emerald-600 dark:text-emerald-400" ],
    "text/csv" => [ "file-spreadsheet", "text-emerald-600 dark:text-emerald-400" ],
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" => [ "presentation", "text-orange-500" ],
    "application/vnd.oasis.opendocument.presentation" => [ "presentation", "text-orange-500" ],
    "application/zip" => [ "file-archive", "text-amber-600 dark:text-amber-400" ]
  }.freeze

  # Label corta del tipo file per la colonna Type. Immagini raggruppate; fallback = subtype.
  def document_type_label(content_type)
    return t("member.documents.types.image") if content_type.to_s.start_with?("image/")
    return t("member.documents.types.text") if content_type == "text/plain"

    DOCUMENT_TYPE_LABELS[content_type] || content_type.to_s.split("/").last.to_s.upcase
  end

  # Lucide icon name for the file type.
  def document_type_icon(content_type) = document_type_icon_spec(content_type).first

  # Colour class that goes with `document_type_icon`.
  def document_type_icon_color(content_type) = document_type_icon_spec(content_type).last

  def document_type_icon_spec(content_type)
    type = content_type.to_s
    return [ "file-image", "text-violet-500" ] if type.start_with?("image/")
    return [ "file-video", "text-sky-500" ] if type.start_with?("video/")

    DOCUMENT_TYPE_ICONS[type] || [ "file-text", "text-gray-400 dark:text-zinc-500" ]
  end

  # PDFs and images the browser can show; Active Storage forces the rest (SVG included) to download.
  def document_viewable_inline?(content_type)
    type = content_type.to_s
    (type == "application/pdf" || type.start_with?("image/")) &&
      ActiveStorage.content_types_allowed_inline.include?(type)
  end
end
