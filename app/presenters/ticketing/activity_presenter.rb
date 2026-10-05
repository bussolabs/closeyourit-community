# frozen_string_literal: true

module Ticketing
  # Trasforma un Ticketing::Event (+ jsonb `data`) in una frase leggibile localizzata e in
  # un'icona per la timeline. Tutto il branching per-action vive qui (testabile in isolamento),
  # non nel partial. Le label nel `data` sono già snapshot umane (vedi RecordActivity).
  class ActivityPresenter
    ICONS = {
      "created" => "circle-plus",
      "updated" => "pen",
      "status_changed" => "refresh-cw",
      "assigned" => "user-check",
      "unassigned" => "user-x",
      "reviewer_changed" => "user-pen",
      "milestone_changed" => "flag",
      "comment_deleted" => "message-circle-off",
      "attached" => "paperclip",
      "attachment_removed" => "unlink",
      "review_rejected" => "rotate-ccw",
      "review_approved" => "circle-check",
      "linked" => "link",
      "branch_created" => "git-branch",
      "pull_request_opened" => "git-pull-request",
      "pull_request_merged" => "git-merge",
      "pull_request_closed" => "git-pull-request",
      # CYRA-609 — l'unione del codice ha provato a chiudere il ticket e la lavorazione ha detto no.
      # Il tentativo resta scritto: senza, una chiusura rifiutata sarebbe indistinguibile da una mai
      # tentata, e chi guarda si chiederebbe perché il ticket è ancora aperto.
      "pull_request_autoclose_declined" => "git-merge",
      # Gate di eleggibilità agenti (CYRA-184): robot = verdetto del modello, scudo = decisione umana.
      "agent_eligibility_evaluated" => "bot",
      "agent_eligibility_overridden" => "shield-half",
      # Chi doveva approvare ha chiesto precisazioni invece di decidere (CYRA-262).
      "clarification_requested" => "circle-question-mark",
      # Fotografia immutabile della guidance consegnata alla presa in carico (CYRA-76).
      "work_context_captured" => "camera",
      # Prerequisiti tra ticket (CYRA-82): grafo per l'aggiunta, scollegamento per la rimozione.
      "dependency_added" => "workflow",
      "dependency_removed" => "unlink",
      # La lavorazione automatica si è fermata davanti a un prerequisito aperto (CYRA-597).
      "dependency_blocked" => "hand",
      # Il lavoro era già fatto nel codice e il ticket si è chiuso da sé (CYRA-675).
      "already_done" => "check-check",
      # Domande e risposte di primo livello (CYRA-779). La chiusura è la domanda RITIRATA: chi
      # ha chiesto non ha più bisogno di sapere, e senza una riga sua resterebbe indistinguibile
      # da una domanda a cui nessuno ha mai risposto.
      "question_asked" => "circle-question-mark",
      "question_answered" => "reply",
      "question_closed" => "circle-x",
      # La consegna è andata avanti da sola perché i controlli erano tutti verdi (CYRA-868).
      "autopilot_auto_approved" => "fast-forward"
    }.freeze

    # Ordine canonico dei campi nella frase `updated`: il jsonb NON preserva l'insertion order,
    # quindi senza questo l'elenco ("titolo, stato") apparirebbe in ordine arbitrario dopo il
    # round-trip in DB. I campi non previsti finiscono in coda (default index).
    FIELD_ORDER = %w[
      title kind description weight scenarios conditions technical_analysis status priority assignee milestone platforms
    ].freeze

    # Transizioni di stato che, quando le compie un'automazione, ottengono una frase dedicata
    # (CYRA-385): non "Tizio ha cambiato lo stato" ma "L'automazione ha portato il ticket in …".
    AUTOMATED_STATUS_ACTIONS = %w[status_changed review_approved review_rejected].freeze

    # `visible_ticket_ids` (CYRA-789): i ticket che CHI LEGGE può vedere fra quelli nominati dalle
    # righe `linked` — un collegamento cross-project è legittimo, conoscerne il codice no. nil = non
    # si sa chi sta leggendo (append realtime: lo stream è UNO per ticket, condiviso da tutti i
    # lettori, quindi la frase non può essere personalizzata) → si tace il codice. Il default è
    # prudente: al ricaricamento della pagina chi ha i permessi lo rilegge per intero.
    def initialize(event, visible_ticket_ids: nil)
      @event = event
      @visible_ticket_ids = visible_ticket_ids
    end

    def icon
      ICONS.fetch(@event.action, "info")
    end

    # L'attore reale è un'automazione (agente/host) quando è un service account. È il segnale che
    # riscrive le frasi di transizione e accende il badge dedicato nel partial, senza inventare nulla:
    # o l'attore registrato è un service account, o non lo è.
    def automated?
      @event.actor&.service? || false
    end

    def sentence
      return automated_status_sentence if automated? && AUTOMATED_STATUS_ACTIONS.include?(@event.action)
      return updated_sentence if @event.action == "updated"
      return reviewer_sentence if @event.action == "reviewer_changed"
      return linked_sentence if @event.action == "linked"
      return agent_eligibility_sentence if @event.action.start_with?("agent_eligibility_")

      I18n.t("member.tickets.activity.#{@event.action}", **interpolations)
    end

    # Nome dell'attore, snapshot-first (resiste alla cancellazione dell'account). Pubblico:
    # riusato dal blocco Audit (vedi TicketsHelper#audit_actor_name) oltre che internamente.
    def actor_name
      @event.actor_name.presence ||
        @event.actor&.name.presence ||
        I18n.t("member.tickets.activity.unknown_actor")
    end

    # CYRA-406 — dietro questa riga c'era un programma, non una persona: o un account di servizio,
    # o un sistema che si è dichiarato per nome senza avere un account (rietichettatura automatica,
    # webhook GitHub). Serve al riquadro di audit per non mostrarlo con le iniziali di una persona.
    def machine? = automated? || (@event.actor_id.nil? && @event.actor_name.present?)

    private

    # Frase impersonale per un cambio di stato compiuto da un'automazione (CYRA-385). Menziona SOLO la
    # destinazione (`to`, label snapshottata e già umana): chi legge vuole sapere dov'è finito il
    # ticket. Il nome dell'attore reale (il service account) vive nel badge accanto, non nella frase —
    # così la riga NON è attribuita a una persona e resta chiara anche senza leggere il nome.
    def automated_status_sentence
      I18n.t("member.tickets.activity.automated.#{@event.action}", to: dig("status", "to"))
    end

    # `updated` aggrega più campi: compone la lista dei campi cambiati (label i18n) dal jsonb.
    # Fallback generico se il diff non porta nomi di campo (difensivo: UpdateTicket#log_changes
    # non emette `updated` con diff vuoto).
    def updated_sentence
      # Tie-break secondario sulla chiave: due campi NON in FIELD_ORDER avrebbero lo stesso rank
      # (size) e sort_by (non stabile) li ordinerebbe in modo arbitrario → la chiave stessa li
      # rende deterministici. Oggi tutte le chiavi sono in FIELD_ORDER, è hardening difensivo.
      keys = @event.data.keys.sort_by { |key| [ FIELD_ORDER.index(key) || FIELD_ORDER.size, key ] }
      fields = keys.map { |key| I18n.t("member.tickets.activity.field.#{key}", default: key.to_s) }
      return I18n.t("member.tickets.activity.updated_generic", actor: actor_name) if fields.empty?

      I18n.t("member.tickets.activity.updated", actor: actor_name, fields: fields.join(", "))
    end

    # Eleggibilità agenti (CYRA-184): il `to` nel jsonb è il valore dell'enum ("allowed"), non una
    # frase — va tradotto, altrimenti la timeline mostrerebbe l'identificatore tecnico a un utente
    # non tecnico. L'evento automatico non ha attore (l'ha deciso il modello), quello di override sì.
    #
    # Due chiavi possibili perché sono due campi diversi (CYRA-770): il giro automatico racconta il
    # PARERE, quello umano la DECISIONE. La vecchia chiave resta letta per seconda — gli eventi
    # scritti prima della separazione sono nel database e devono continuare a leggersi.
    def agent_eligibility_sentence
      to = (dig("agent_eligibility_advice", "to") || dig("agent_eligibility", "to")).to_s
      value = I18n.t("member.tickets.activity.agent_eligibility_value.#{to}", default: to)
      I18n.t("member.tickets.activity.#{@event.action}", actor: actor_name, to: value)
    end

    # CYRA-789 — il collegamento fra ticket attraversa i progetti di proposito (il gate duplicati lo
    # crea verso il ticket che ha suggerito questo), quindi la riga può nominare un ticket che chi
    # legge non ha diritto di conoscere: il codice porta con sé la chiave del progetto e l'esistenza
    # del ticket. Esce solo a chi quel ticket lo vede davvero; altrimenti resta il fatto (qualcuno ha
    # collegato qualcosa, e di che tipo di legame si tratta).
    #
    # Il permesso si decide sull'ID scritto nell'evento, MAI sul codice: la chiave di progetto è
    # un'etichetta rinominabile, e può essere riassegnata a un altro progetto — un confronto fra
    # stringhe farebbe cambiare padrone al permesso insieme al nome. Gli eventi scritti prima di
    # CYRA-789 non portano l'id e restano senza codice: meno leggibili, mai indiscreti.
    def linked_sentence
      kind = I18n.t("member.tickets.links.kind.#{@event.data['kind']}", default: @event.data["kind"].to_s)
      return I18n.t("member.tickets.activity.linked_hidden", actor: actor_name, kind: kind) unless linked_ticket_visible?

      I18n.t("member.tickets.activity.linked", actor: actor_name, ticket: @event.data["ticket"].to_s, kind: kind)
    end

    def linked_ticket_visible?
      id = @event.data["ticket_id"]
      id.present? && @visible_ticket_ids.present? && @visible_ticket_ids.include?(id)
    end

    # reviewer_changed è un'unica action con data {from, to}: to nil = revisore rimosso. Due chiavi
    # (impostato/rimosso) come per l'assegnazione, ma senza sdoppiare l'action nell'allow-list.
    def reviewer_sentence
      to = dig("reviewer", "to")
      key = to.present? ? "reviewer_changed" : "reviewer_removed"
      I18n.t("member.tickets.activity.#{key}", actor: actor_name, to: to)
    end

    # Solo i placeholder usati dalla chiave dell'action (gli extra verrebbero comunque ignorati
    # da I18n, ma teniamo l'hash minimo e leggibile).
    def interpolations
      base = { actor: actor_name }
      case @event.action
      # La reason del reject NON è interpolata nella frase: il testo vive nel commento creato
      # dallo stesso rifiuto (niente dato doppio in timeline); nel data resta solo per audit/CLI.
      when "status_changed", "review_rejected", "review_approved"
        base.merge(from: dig("status", "from"), to: dig("status", "to"))
      when "assigned"
        base.merge(to: dig("assignee", "to"))
      when "attached"
        # Separatore " · " (non virgola): un filename può contenere virgole → ambiguità.
        base.merge(filenames: Array(@event.data["filenames"]).join(" · "))
      when "attachment_removed"
        base.merge(filename: @event.data["filename"])
      when "comment_deleted"
        base.merge(author: @event.data["author_name"])
      # CYRA-597 — la lavorazione automatica si è fermata davanti a un prerequisito aperto. La frase
      # dice quanti sono e quali: senza i codici, chi legge sa che si è fermato ma non cosa aspettare.
      when "dependency_blocked"
        codes = Array(@event.data["dependencies"]).filter_map { |d| d["code"] }
        base.merge(count: @event.data["open_count"].to_i, dependencies: codes.join(", "))
      # `linked` non passa di qui: la sua frase dipende da chi legge (CYRA-789) → linked_sentence.
      # Dipendenze (CYRA-82): il `data` porta lo snapshot {code, title} del blocker; la frase mostra
      # il code (il title resta nel data per audit, come per gli altri snapshot umani).
      when "dependency_added", "dependency_removed"
        base.merge(ticket: @event.data["code"])
      # CYRA-675 — il ticket si è chiuso perché il lavoro era già scritto. La frase dice DOVE: senza i
      # file, «era già fatto» è una parola d'onore, e una chiusura automatica va poter rimessa in
      # discussione da chi la legge. Il riassunto per esteso resta nel dato e nella scheda Automazione,
      # come per la motivazione di un rifiuto: in timeline ci sta una riga, non un racconto.
      when "already_done"
        paths = Array(@event.data["sources"]).filter_map { |source| source["path"] }
        base.merge(count: paths.size, files: activity_file_list(paths))
      # CYRA-868 — la consegna è passata da sola: la frase dice SU QUALI controlli, perché «era tutto
      # verde» senza i nomi è una parola d'onore. L'elenco completo resta nel dato dell'evento.
      when "autopilot_auto_approved"
        names = Array(@event.data["checks"]).map(&:to_s)
        base.merge(count: names.size, checks: activity_file_list(names))
      when "branch_created"
        base.merge(branch: @event.data["branch"])
      when "pull_request_opened", "pull_request_merged", "pull_request_closed", "pull_request_autoclose_declined"
        base.merge(number: @event.data["number"])
      else
        base
      end
    end

    # I primi file, e quanti restano. Un elenco lungo in timeline diventa un muro, e la riga serve a
    # far capire dove guardare, non a essere esaustiva: il resto e nel dato dell'evento.
    def activity_file_list(paths, limit: 3)
      shown = paths.first(limit)
      return shown.join(" · ") if paths.size <= limit

      "#{shown.join(" · ")} #{I18n.t("member.tickets.activity.more_files", count: paths.size - limit)}"
    end

    def dig(*keys)
      @event.data.dig(*keys)
    end
  end
end
