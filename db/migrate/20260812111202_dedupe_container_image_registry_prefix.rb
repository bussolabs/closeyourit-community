# frozen_string_literal: true

# CYRA-464 — l'indirizzo di provenienza dei container arrivava col prefisso del registro RIPETUTO
# (`registry.esempio.it/registry.esempio.it/org/app`). La raccolta è già stata corretta; qui si
# ripuliscono le righe già salvate, altrimenti la storia resta sporca e la lettura dovrebbe
# continuare a compensare un difetto che non esiste più.
#
# Solo il caso esatto — primo segmento uguale al secondo — e solo dove si ripete davvero: nessuna
# euristica sui nomi dei registri.
class DedupeContainerImageRegistryPrefix < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL.squish)
      UPDATE servers_container_samples
         SET image = substring(image from position('/' in image) + 1)
       WHERE image IS NOT NULL
         AND position('/' in image) > 0
         AND split_part(image, '/', 1) = split_part(image, '/', 2)
    SQL
  end

  # Irreversibile per costruzione: il prefisso duplicato era un difetto, non un dato.
  def down = nil
end
