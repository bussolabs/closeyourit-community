# frozen_string_literal: true

# CYRA-28 — Sorgente UNICA delle scorciatoie da tastiera globali del layout member. Lo stesso array
# di destinazioni alimenta sia la LOGICA del controller `keyboard` (data-keyboard-nav-value) sia la
# DOC dell'help condiviso (partial member/_keyboard_help) → binding e documentazione non divergono.
module KeyboardHelper
  # Destinazioni sidebar raggiungibili con `g <lettera>`, filtrate con gli STESSI gate di visibilità
  # del layout (member.html.erb). Ritorna [] senza organizzazione (nessuna navigazione ha senso).
  def keyboard_nav_bindings
    return [] unless current_organization

    bindings = [
      { key: "h", url: root_path,                            label: t("member.nav.home") },
      { key: "a", url: member_home_approvals_path,           label: t("member.approvals.title") },
      { key: "t", url: member_tickets_path,                  label: t("member.nav.tickets") },
      { key: "i", url: member_ideas_path,                    label: t("member.nav.ideas") },
      # CYRA-365 — le attività personali sono uno dei quattro posti dove si annota qualcosa da fare:
      # ci si arriva da tastiera come agli altri tre, non solo cliccando un'icona.
      { key: "d", url: member_todo_lists_path,               label: t("member.nav.todos") },
      { key: "p", url: member_projects_path,                 label: t("member.nav.projects") },
      { key: "k", url: member_knowledge_pages_path,          label: t("member.nav.knowledge") }
    ]
    # CYRA-586 — le tre destinazioni tecniche seguono il gate della voce di menu: a un cliente
    # esterno che non le ha in elenco, la scorciatoia aprirebbe la stessa pagina vuota per un'altra
    # strada, e l'aiuto da tastiera la elencherebbe come se ci fosse.
    bindings << { key: "e", url: member_monitoring_error_groups_path, label: t("member.nav.errors") } if errors_nav_visible?
    bindings << { key: "l", url: member_monitoring_log_entries_path,  label: t("member.nav.logs") }   if logs_nav_visible?
    bindings << { key: "u", url: member_monitoring_monitors_path,     label: t("member.nav.uptime") } if uptime_nav_visible?
    bindings << { key: "w", url: member_workload_actions_path,       label: t("member.nav.workload") } if workload_nav_visible?
    bindings << { key: "s", url: member_monitoring_servers_path,     label: t("member.nav.servers") }  if servers_nav_visible?
    bindings
  end

  # Riga dell'help: label + tasto in <kbd>. Usata dalla parte universale (server-side) del partial;
  # la parte "questa pagina" costruisce righe equivalenti a runtime nel controller `keyboard`.
  def keyboard_help_row(label, keys)
    tag.li(class: "flex items-center justify-between gap-4") do
      tag.span(label) +
        tag.kbd(keys, class: "font-mono text-[11px] bg-stone-100 dark:bg-zinc-800 border border-stone-200 dark:border-zinc-800 rounded px-1.5 py-0.5")
    end
  end

  # Binding di una board Kanban da dichiarare via [data-keyboard-doc] (raccolti nell'help condiviso).
  # Il set completo (grab/move/annulla) è per chi può gestire; in sola lettura resta la sola selezione.
  def board_keyboard_docs(can_manage:)
    docs = [ { keys: "↑ ↓", label: t("member.keyboard.board.select") } ]
    if can_manage
      docs << { keys: t("member.keyboard.board.grab_keys"), label: t("member.keyboard.board.grab") }
      docs << { keys: "← →",                                label: t("member.keyboard.board.move") }
      docs << { keys: "Esc",                                label: t("member.keyboard.board.cancel") }
    end
    docs
  end

  # Tasti della home decisioni, dichiarati via [data-keyboard-doc] (CYRA-862).
  # CYRA-899 — the approvals board: move between rows and act on the focused one.
  def approvals_board_keyboard_docs
    [ { keys: "j", label: t("member.keyboard.approvals_board.next") },
      { keys: "k", label: t("member.keyboard.approvals_board.prev") },
      { keys: "Enter", label: t("member.keyboard.approvals_board.open") },
      { keys: "a", label: t("member.keyboard.approvals_board.approve") },
      { keys: "x", label: t("member.keyboard.approvals_board.select") } ]
  end

  def decision_keyboard_docs
    [ { keys: "a", label: t("member.keyboard.decision.approve") },
      { keys: "r", label: t("member.keyboard.decision.reject") },
      { keys: "s", label: t("member.keyboard.decision.skip") },
      { keys: "d", label: t("member.keyboard.decision.defer") } ]
  end
end
