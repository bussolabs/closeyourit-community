# frozen_string_literal: true

# Riga di un dataset (Datasets::Row) per la CLI. `values` è la mappa codice colonna → valore scalare,
# la stessa forma con cui la riga si scrive (`values[colore]=rosso`): chi legge una riga sa già come
# rimandarla indietro. `photos` è il suo gemello per le celle foto — solo i metadati del file, mai un
# URL firmato: il binario si prende dall'endpoint `photos/:code`, che lo consegna con tipo neutro e
# disposition attachment.
class DatasetRowSerializer < ApplicationSerializer
  attributes :id, :dataset_id, :position, :created_at, :updated_at

  attribute(:purpose) { |row| row.purpose }
  attribute(:values)  { |row| row.cell_values || {} }
  attribute(:photos)  { |row| DatasetRowSerializer.photos(row) }

  # Le celle foto della riga, indicizzate per codice di colonna. Una cella senza blob allegato non
  # compare: significa che quella foto non c'è, e una voce coi campi a nulla direbbe il contrario.
  def self.photos(row)
    row.cells.each_with_object({}) do |cell, photos|
      blob = cell.image.blob
      next if blob.nil?

      photos[cell.column.code] = { filename: blob.filename.to_s, byte_size: blob.byte_size,
                                   content_type: blob.content_type }
    end
  end
end
