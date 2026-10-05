module ApplicationHelper
  # CYRA-715 — dichiara nell'head se la Content Security Policy di QUESTA pagina blocca o solo
  # segnala, e lo marca `data-turbo-track="reload"`.
  #
  # Serve a un guasto che non si vede: la policy attiva è quella del PRIMO documento caricato, e
  # Turbo navigando non la sostituisce. Chi entrava dal sito pubblico (dove la policy segnala e
  # basta) e premeva «Accedi» si portava dietro quella policy per tutta la visita nell'area
  # riservata: l'enforce c'era negli header e non nel browser. Nessun errore, nessun segno.
  #
  # Con questo meta i due canali hanno elementi tracciati DIVERSI, e Turbo ricarica da capo ogni
  # volta che si passa da uno all'altro — in tutte e due le direzioni, anche per un link scritto
  # domani. Dentro lo stesso canale il valore non cambia e non si ricarica niente.
  def csp_mode_meta_tag
    mode = request.content_security_policy_report_only ? "report" : "enforce"
    tag.meta(name: "csp-mode", content: mode, "data-turbo-track": "reload")
  end

  # Mappa i tipi di flash Rails sulle varianti di Ui::AlertComponent.
  def flash_variant(type)
    case type.to_sym
    when :notice then :success
    when :alert  then :danger
    when :warning then :warning
    else :info
    end
  end

  # Iniziali per gli avatar (max 2 lettere, dal nome).
  def avatar_initials(name)
    name.to_s.split.map { |word| word[0] }.first(2).join.upcase.presence || "?"
  end

  # Nome visualizzato dell'account: il nome se presente, altrimenti la mail.
  def account_display_name(account = Current.account)
    account&.name.presence || account&.email
  end

  # Nome dell'attore di un Activity::Event per il blocco Audit (snapshot-first). nil se l'evento
  # non c'è → il blocco Audit omette l'autore dell'aggiornamento.
  def activity_actor_name(event)
    event && Activity::Presenter.new(event).actor_name
  end

  # Un god sta impersonando un altro account?
  def impersonating?
    Current.session&.impersonating?
  end

  # Colore Ui::BadgeComponent per il code di un environment (release/errori/log). Allineato ai
  # colori di default di Types::InstallDefaults; fuori mappa → neutro.
  def environment_badge_color(code)
    { "production" => :emerald, "staging" => :amber, "development" => :sky }.fetch(code.to_s, :gray)
  end

  # CYRA-568 — il conteggio di una lista, scritto sempre allo stesso modo. La forma singolare o
  # plurale la sceglie il numero VERO (passare a `count:` una stringa già formattata farebbe cadere
  # ogni conteggio su «other», cioè «1 logs»), le migliaia le scrive la lingua. Senza questo,
  # `t("...", count: @pagination.total)` stampava «4031» accanto al «4.031» del piede di
  # paginazione: due forme dello stesso numero nella stessa schermata.
  # La riscrittura tocca la PRIMA occorrenza del conteggio nella frase tradotta — le altre
  # interpolazioni arrivano già scritte da chi chiama — e sotto il migliaio non fa niente.
  def count_label(key, total, **options)
    number = total.to_i
    formatted = number_with_delimiter(number)
    text = t(key, count: number, **options)
    formatted == number.to_s ? text : text.sub(number.to_s, formatted)
  end

  # Badge di uno status ticket: pallino del colore dello status, che "respira" se
  # lo status è marcato animated (data-driven, vedi Types::TicketStatus#animated).
  def ticket_status_badge(status, test_id: nil)
    render Ui::BadgeComponent.new(
      label: status.display_label,
      color: status.color,
      dot: true,
      pulse: status.animated,
      test_id: test_id
    )
  end
end
