# frozen_string_literal: true

# Cella della matrice (Connections::FeaturePlatform): l'incrocio [funzionalità, piattaforma].
# Non ha un id proprio da esporre — l'identità È la coppia, ed è così che la si referenzia.
#
# Stato e versione arrivano annidati e non come id nudi: da terminale un UUID non dice niente,
# mentre `status.code` e `release.version` sono esattamente i valori che si ripassano in scrittura.
# `release_missing` è la stessa segnalazione della matrice web: lo stato dice "è nelle mani degli
# utenti" ma non sappiamo da quando (dato incompleto, non errore).
class FeatureCellSerializer < ApplicationSerializer
  attributes :feature_id, :platform_id

  # Il code viaggia con l'id per lo stesso motivo di `category_name` in FeatureSerializer: da
  # terminale un UUID di piattaforma non dice niente, e senza questo chi legge le celle di una
  # funzionalità dovrebbe incrociarle a mano con l'elenco delle piattaforme.
  attribute :platform_code do |cell|
    cell.platform&.code
  end

  attribute :status do |cell|
    next nil if cell.status.blank?

    { id: cell.status.id, code: cell.status.code, label: cell.status.label, category: cell.status.category }
  end

  attribute :release do |cell|
    next nil if cell.release.blank?

    { id: cell.release.id, version: cell.release.version, project_key: cell.release.project&.key }
  end

  attribute :release_missing, &:release_missing?
end
