# frozen_string_literal: true

module TicketsHelper
  # Colore del badge per kind: bug→red, story→violet, task→sky, epic→amber (palette Tailwind nativa).
  KIND_COLORS = { "bug" => :red, "story" => :violet, "task" => :sky, "epic" => :amber }.freeze

  def ticket_kind_color(kind) = KIND_COLORS.fetch(kind.to_s, :gray)

  # Colore del badge di eleggibilità agenti (CYRA-184): da valutare→amber (in attesa), consentito→
  # emerald, bloccato→red. Il default gray non è raggiungibile dall'enum: è la rete per un valore
  # sconosciuto, che non deve mai leggersi come "consentito".
  AGENT_ELIGIBILITY_COLORS = { "pending" => :amber, "allowed" => :emerald, "blocked" => :red }.freeze

  def agent_eligibility_color(eligibility) = AGENT_ELIGIBILITY_COLORS.fetch(eligibility.to_s, :gray)

  # CYRA-924 — Board or List as a View menu section (C62). The links carry the common filters; the
  # tickets-view-switch controller rebuilds them from the address at click time (CYRA-901).
  def ticket_view_sections(current)
    board_list_view_sections(current, scope: "tickets", keys: Ticketing::Constants::VIEW_SHARED_FILTERS,
                                      board: :member_tickets_path, list: :list_member_tickets_path,
                                      label_scope: "member.tickets.view_switch")
  end

  # K13 — a board card title with the searched words highlighted; words under two letters are skipped.
  def board_card_title(title, query)
    words = query.to_s.split.select { |word| word.length >= 2 }
    return title if words.empty?

    # Split on the words instead of Rails' `highlight`, which reads the title as HTML: a literal tag in a
    # title would render. Each piece goes through safe_join, so it is escaped.
    pattern = Regexp.new("(#{words.map { |word| Regexp.escape(word) }.join('|')})", Regexp::IGNORECASE)
    safe_join(title.split(pattern).map.with_index do |part, index|
      index.odd? ? tag.mark(part, class: "rounded-sm bg-amber-100 dark:bg-amber-500/25 px-0.5 text-inherit") : part
    end)
  end

  # Shared by Tickets and Workload actions: the same switch, the same controller, their own keys.
  def board_list_view_sections(current, scope:, keys:, board:, list:, label_scope:)
    carried = request.query_parameters.slice(*keys).merge(RememberableFilters::MARKER_PARAM.to_s => "1")
    choices = { "board" => board, "list" => list }.map do |view, route|
      { label: t("#{label_scope}.#{view}"), href: public_send(route, carried), active: view == current,
        test_id: "#{scope}-view-#{view}", data: { turbo_frame: "_top", action: "click->tickets-view-switch#follow" } }
    end
    [ { heading: t("shared.tables.show_as"), choices: choices,
        data: { test: "#{scope}-view-switch", controller: "tickets-view-switch",
                tickets_view_switch_marker_value: RememberableFilters::MARKER_PARAM,
                tickets_view_switch_keys_value: keys.to_json } } ]
  end

  # Classi LITERAL (Tailwind non vede le stringhe interpolate a runtime) per l'icona robot che marca
  # ogni card/riga ticket: acceso solo dove un agente può davvero lavorare. Il default grigio è la
  # rete fail-closed — un valore sconosciuto si legge "non lavorabile", mai il contrario.
  AGENT_ELIGIBILITY_ICON_CLASSES = {
    "pending" => "text-amber-500 dark:text-amber-400", "allowed" => "text-emerald-600 dark:text-emerald-400", "blocked" => "text-gray-300 dark:text-zinc-600"
  }.freeze

  def agent_eligibility_icon_class(eligibility)
    AGENT_ELIGIBILITY_ICON_CLASSES.fetch(eligibility.to_s, "text-gray-300 dark:text-zinc-600")
  end

  # CYRA-403 — la GLIFA, non solo il colore: grigio contro arancione su quattordici pixel non si
  # distingue con un deficit di visione dei colori, e quell'icona dice come si divide il lavoro fra
  # le automazioni e le persone. Robot = la macchina può prenderlo, persona = resta a un umano,
  # clessidra = non è ancora stato deciso. Il default segue il caso «solo per una persona»
  # (fail-closed, come il colore).
  AGENT_ELIGIBILITY_ICONS = {
    "pending" => "hourglass", "allowed" => "bot", "blocked" => "user"
  }.freeze

  def agent_eligibility_icon(eligibility) = AGENT_ELIGIBILITY_ICONS.fetch(eligibility.to_s, "user")

  # Riga informativa sotto il titolo della ticket-show (CYRA-392, rivede CYRA-65): SEMPRE "creato il
  # <data>". Sui ticket non ancora conclusi aggiunge da quanto sono fermi nello stato corrente. Il
  # vecchio "aperto da X" contava i giorni dalla creazione anche su un ticket chiuso, mostrando un
  # tempo falso ("aperto da 10 giorni" su un Risolto); "creato il …" è vero a percorso finito, e il
  # tempo di permanenza compare solo dove ha senso — su un ticket ancora in movimento.
  def ticket_created_line(ticket)
    created = t("member.tickets.show.created_on", date: l(ticket.created_at, format: :long))
    return created if ticket.status&.category_done?

    in_status = t("member.tickets.show.in_status_since", time: time_ago_in_words(ticket.current_status_since))
    "#{created} · #{in_status}"
  end

  # Tooltip del chip "In corso" (CYRA-392): elenca gli status che il conteggio somma, così la chip
  # dichiara di aggregare più stati (In lavorazione + In revisione) invece di nasconderlo. nil — che
  # tag.span non emette come attributo — quando non c'è nessuno status "in corso" da elencare.
  def in_progress_chip_title(labels)
    return nil if labels.blank?

    t("member.tickets.in_progress_hint", statuses: labels.join(", "))
  end

  # Nome dell'attore di un evento per la sezione Audit (snapshot resistente alla cancellazione
  # dell'account). nil se l'evento non c'è → il blocco Audit omette l'autore.
  def audit_actor_name(event) = event && Ticketing::ActivityPresenter.new(event).actor_name

  # CYRA-406 — se dietro la modifica c'era un programma, l'audit lo mostra con l'icona della
  # macchina invece che con le iniziali dentro un cerchio.
  def audit_actor_machine?(event) = event.present? && Ticketing::ActivityPresenter.new(event).machine?

  # Chi tiene il ticket, in chiaro: il nome della persona o il nome della macchina che esegue
  # l'agente. Il fallback copre il titolare cancellato mentre il lease è ancora vivo.
  def ticket_lease_holder_name(lease)
    name = lease.human? ? lease.account&.name : lease.host&.hostname
    name.presence || t("member.tickets.lease.unknown_holder")
  end

  # CYRA-405 — chi ha scritto l'analisi e quando. Non c'è una colonna: la verità sta nella cronologia
  # del ticket, dove ogni modifica registra chi l'ha fatta e cosa ha toccato. Senza nessuna modifica
  # all'analisi vale la creazione del ticket, che è quando il testo è nato.
  def ticket_analysis_signature(ticket)
    event = ticket.events.select { |e| e.action == "updated" && e.data.to_h.key?("technical_analysis") }
                   .max_by(&:created_at)
    return { name: event.actor_name.presence || t("member.tickets.show.written_by_system"), at: event.created_at } if event

    { name: ticket.reporter&.name || t("member.tickets.show.written_by_system"), at: ticket.created_at }
  end

  # Riga «scritta da X il giorno Y», uguale per l'analisi e per il piano.
  def ticket_written_line(name:, at:)
    t("member.tickets.show.written_by", name: name, date: l(at, format: :long))
  end

  # CYRA-374 — il ticket aspetta una decisione di CHI STA GUARDANDO: è il badge della riga di lista.
  # Predicato in memoria (lo status è precaricato), quindi nessuna query per riga. Le card di board
  # non passano di qui: sono rese anche dai broadcast, dove `Current` non esiste, e ricevono un
  # booleano già calcolato.
  def ticket_awaiting_decision?(ticket)
    ticket.awaiting_review_by?(Current.account)
  end
end
