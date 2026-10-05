# frozen_string_literal: true

# Presentazione della matrice funzionalità × piattaforme.
module ProductHelper
  # Icona della cella derivata dalla CATEGORY dello stato (non dal code, che è rinominabile):
  # una lookup personalizzata dall'org continua a mostrare l'icona giusta.
  FEATURE_STATUS_ICONS = {
    "unplanned" => "minus",
    "planned" => "calendar",
    "in_development" => "hammer",
    "available" => "check",
    "deprecated" => "arrow-down",
    "not_applicable" => "ban"
  }.freeze

  def feature_status_icon(status)
    FEATURE_STATUS_ICONS.fetch(status&.category.to_s, "circle")
  end

  # Id del turbo frame di una cella: [funzionalità, piattaforma] è la sua identità, anche quando
  # la cella non esiste ancora (incrocio vuoto da riempire).
  def feature_cell_frame_id(feature, platform)
    "feature-cell-#{feature.id}-#{platform.id}"
  end

  # Etichetta di una versione indicabile. Il progetto sta NEL label perché Ui::SelectComponent non
  # ha optgroup, e un prodotto con più repo mostrerebbe altrimenti versioni indistinguibili.
  # "live" = la release che gira ora; l'ambiente compare solo quando non è produzione.
  def release_candidate_label(release)
    parts = [ "#{release.project.name} · #{release.display_version}" ]
    parts << t("member.product.cells.live") if release.current?
    parts << release.environment if release.environment != ::Projects::Release::DEFAULT_ENVIRONMENT
    parts.join(" · ")
  end
end
