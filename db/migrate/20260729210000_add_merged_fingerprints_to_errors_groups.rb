# frozen_string_literal: true

# I fingerprint dei gruppi assorbiti da una fusione (CYRA-192).
#
# Senza questo il merge non tiene: il fingerprint è la chiave con cui l'ingest ritrova il gruppo
# (`find_or_create_by!(fingerprint:)`), quindi cancellando un gruppo assorbito la prima occorrenza
# successiva con quel fingerprint ne ricrea uno nuovo — e la riga che si era appena fusa ricompare
# nell'elenco come se niente fosse. Tenendo qui i fingerprint assorbiti, l'ingest li risolve al
# primario e le occorrenze continuano ad arrivare dove le abbiamo mandate.
class AddMergedFingerprintsToErrorsGroups < ActiveRecord::Migration[8.1]
  def change
    add_column :errors_groups, :merged_fingerprints, :text, array: true, default: [], null: false,
               comment: "Fingerprint dei gruppi assorbiti da una fusione: l'ingest li risolve a questo gruppo"
    # GIN perché il lookup dell'ingest è un contains su array (`@>`), sul path caldo.
    add_index :errors_groups, :merged_fingerprints, using: :gin
  end
end
