# frozen_string_literal: true

module IdeasHelper
  # Colore del badge di stato idea (chiavi di Ui::BadgeComponent::COLORS).
  STATUS_COLORS = { "open" => :emerald, "converted" => :indigo, "archived" => :gray }.freeze

  def idea_status_color(status) = STATUS_COLORS.fetch(status.to_s, :gray)

  # Conferma di eliminazione: su un'idea già promossa dice cosa si rompe davvero — il filo verso
  # il ticket nato da lì, non solo voti e commenti. Se quel ticket è già stato eliminato (backlink
  # nullify) il collegamento non c'è più da perdere: torna la conferma standard, senza nominare
  # un codice che non esiste.
  def idea_delete_confirm(idea)
    ticket = idea.ticket if idea.status_converted?
    return t("member.ideas.delete_confirm") if ticket.blank?

    t("member.ideas.delete_confirm_converted", code: ticket.code)
  end

  # One plain line of the problem for the list: markdown marks dropped, cut at a word.
  def idea_problem_excerpt(idea, length: 110)
    truncate(idea.problem.to_s.gsub(/[#*_`>~\[\]]/, "").squish, length: length, separator: " ")
  end

  # Status chip as a filter: a click shows only that status, a second click switches it off. The
  # other filters stay; the marker stops the remembered status from coming back.
  def idea_status_chip_href(status)
    others = request.query_parameters.except("status", "page")
    return member_ideas_path(others.merge(RememberableFilters::MARKER_PARAM => "1")) if idea_status_chip_active?(status)

    member_ideas_path(others.merge("status" => [ status ]))
  end

  def idea_status_chip_active?(status)
    Array(params[:status]).compact_blank == [ status ]
  end

  # Cards | table switch links, keeping every other filter.
  def ideas_view_href(view)
    member_ideas_path(request.query_parameters.except("page").merge("view" => view))
  end

  # CYRA-924 — Cards or Table as a View menu section (C62); the choice travels in the address.
  def ideas_view_sections(current)
    choices = %w[cards table].map do |view|
      { label: t("member.ideas.view_switch.#{view}"), href: ideas_view_href(view), active: view == current,
        test_id: "ideas-view-#{view}", data: { turbo_frame: "_top" } }
    end
    [ { heading: t("shared.tables.show_as"), choices: choices, data: { test: "ideas-view-switch" } } ]
  end
end
