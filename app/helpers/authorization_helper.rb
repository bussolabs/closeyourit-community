# frozen_string_literal: true

module AuthorizationHelper
  # Label leggibile di una chiave permesso. Le chiavi hanno un PUNTO nel nome (es. "tickets.edit") e nei
  # locale sono chiavi LETTERALI (`"tickets.edit": ...`): `I18n.t("...tickets.edit")` splitterebbe sul
  # punto → translation_missing. Qui risolviamo la chiave letterale nell'hash del sottoalbero
  # `authorization.permissions`. Fallback: la chiave stessa. Memoizzato per-render.
  def authorization_permission_label(key)
    @authorization_permission_labels ||= I18n.t("authorization.permissions")
    @authorization_permission_labels[key.to_sym] || key
  end

  # CYRA-439 — cosa comporta concederlo, in una riga. Stesso trucco della label (chiave letterale
  # col punto). Nil se non c'è: meglio niente che una riga inventata su un permesso vero.
  def authorization_permission_description(key)
    @authorization_permission_descriptions ||= I18n.t("authorization.permission_descriptions")
    @authorization_permission_descriptions[key.to_sym]
  end

  def authorization_permission_dangerous?(key) = Authorization::Catalog.dangerous?(key.to_s)

  # CYRA-695 — la conferma prima di cancellare un ruolo o un team. Sta qui, non nelle due viste, perché
  # elenco e modulo di modifica devono dire la stessa cosa: la conseguenza, col numero vero di chi
  # resta senza quei permessi. I conteggi arrivano già calcolati dall'elenco (una query per pagina,
  # non una per riga) e si calcolano qui soltanto per il singolo record del modulo.
  def role_delete_confirm(role, teams: nil, members: nil)
    teams ||= Authorization::TeamRole.where(role_id: role.id).count
    members ||= Authorization::AccountRole.where(role_id: role.id).count
    t("member.roles.delete_confirm", name: role.name,
                                     members: t("member.roles.used_members", count: members),
                                     teams: t("member.roles.used_teams", count: teams))
  end

  def team_delete_confirm(team, members: nil)
    members ||= team.members.size
    t("member.teams.delete_confirm", name: team.name,
                                     members: t("member.teams.used_members", count: members))
  end

  # Le aree toccate da un ruolo, già tradotte: «Ticket, Progetti, Persone», con «+N» oltre le prime
  # tre — un elenco lungo in una cella di tabella non si legge.
  #
  # CYRA-574 — niente testo di ripiego sul nome dell'area: mascherava qui il buco che la pagina dei
  # permessi mostrava senza rete (fra nomi italiani usciva «knowledge», minuscolo). Il nome di
  # un'area nuova lo pretende `spec/services/authorization/catalog_metadata_spec.rb`.
  def authorization_area_summary(keys, limit: 3)
    areas = Authorization::Catalog.areas_for(keys).map { |area| t("authorization.areas.#{area}") }
    return t("member.roles.no_permissions") if areas.empty?

    shown = areas.first(limit)
    rest = areas.size - shown.size
    rest.positive? ? "#{shown.join(', ')} +#{rest}" : shown.join(", ")
  end
end
