# frozen_string_literal: true

module Member
  # Resa della plancia delle approvazioni (CYRA-592): una riga per lavorazione, una colonna per
  # ciascuna delle cinque fasi.
  module ApprovalsBoardHelper
    # Come si legge una cella. Il colore dice l'ESITO del passaggio, non a che punto è la riga:
    # verde fatto, indaco aspetta una persona (è quella su cui agire), rosso respinta, grigio non
    # ancora raggiunta. La classe della cella è una stringa intera e letterale — una costruita non
    # finirebbe nel CSS, perché lo scanner di Tailwind legge il sorgente, non il risultato.
    CELL_STYLES = {
      "done" => { icon: "circle-check", cell: "", mark: "text-emerald-500" },
      # L'unica cella con lo sfondo: è ciò che rende leggibile una colonna dall'alto in basso.
      "current" => { icon: nil, cell: "bg-indigo-50 dark:bg-indigo-500/15", mark: "bg-indigo-600" },
      "failed" => { icon: "circle-x", cell: "bg-red-50 dark:bg-red-500/15", mark: "text-red-500 dark:text-red-400" },
      "pending" => { icon: nil, cell: "", mark: "bg-stone-200 dark:bg-zinc-700" }
    }.freeze

    def approval_cell_style(state) = CELL_STYLES.fetch(state.to_s, CELL_STYLES.fetch("pending"))

    # Il passaggio con LE STESSE parole delle intestazioni: sono le uniche in cui il nome compare.
    # CYRA-619 — le SEI parole del modello, non i nomi interni delle fasi della macchina: sono le
    # stesse con cui il ticket dice dove si trova, quindi fra la griglia e la colonna dello stato non
    # resta niente da tradurre a mente.
    def approval_phase_name(step) = t("member.tickets.automation.stage.#{step}")

    # CYRA-1057 — a stopped plan restarts from the board: its own Retry button and, CYRA-1060, a checkbox.
    def approval_row_retryable?(row) = row.state == "review_blocked" && row.ticket_id.present?

    # CYRA-1059 — a row key as the board writes it (`kind:id`); anything else targets no row.
    ROW_KEY = /\A[a-z_]+:[\w-]+\z/

    # CYRA-1059 — the id of a board row (and of its preview), targeted by the answer of a row action.
    def approval_row_dom_id(key, part = nil) = [ "approvals-row", key.to_s.tr(":", "-"), part ].compact.join("-")

    # Cosa dice la cella a chi non vede i colori (title + lettori di schermo): il nome del passaggio
    # e il suo esito. Senza, una griglia di puntini è muta.
    def approval_cell_title(cell)
      t("member.approvals.board.cell.#{cell.state}", phase: approval_phase_name(cell.phase))
    end

    # CYRA-610 — le due righe che si leggono PRIMA di approvare un piano: dove il lavoro potrà
    # nascere, e come si proverà che è finito. Nil quando non c'è niente da dire (non è una fase in
    # cui si approva un piano): una riga vuota in cima alla scheda è rumore.
    #
    # Le compone dallo stesso posto da cui l'approvazione le scriverà. Due sorgenti diverse per la
    # riga che leggi e per il dato che viene scritto sarebbero due cose che possono divergere — e
    # divergerebbero proprio nel momento in cui la riga serve a decidere.
    def approval_freeze_lines(ticket)
      decision = ::Agents::Plan.decision_for(ticket)
      return [] unless decision.frozen?

      item = decision.candidate_items.first
      [
        t("member.approvals.board.freeze.scope", repo: item["repo"], base: item["base"]),
        t("member.approvals.board.freeze.probe_#{decision.completion_probe['kind']}")
      ]
    end

    # L'avviso quando manca un pezzo. Dice QUALE manca: «non c'è l'archivio» e «non è stato detto
    # come si prova il rilascio» si sistemano in due posti diversi, e un avviso unico manda a cercare.
    # Nil quando non manca niente.
    def approval_freeze_warning(ticket)
      missing = ::Agents::Plan.decision_for(ticket).missing
      return if missing.nil?

      t("member.approvals.board.freeze.missing_#{missing}")
    end

    # Da quanto la riga aspetta, con la stessa formattazione delle durate delle macchine (2g 04h).
    # Nil quando l'ancora d'età non c'è: un trattino dice «non lo so», che è la verità.
    def approval_wait(since, now: Time.current)
      return "—" if since.blank?

      agent_duration(now - since)
    end

    # CYRA-899 — the wait as a traffic light. Unknown reads as fresh: no age is no alarm.
    AGING_WAIT = 8.hours
    STALE_WAIT = 2.days
    WAIT_CLASSES = {
      fresh: "text-gray-500 dark:text-zinc-400",
      aging: "text-amber-600 dark:text-amber-400 font-semibold",
      stale: "text-red-600 dark:text-red-400 font-semibold"
    }.freeze

    def approval_wait_tone(since, now: Time.current)
      return :fresh if since.blank?

      age = now - since
      return :stale if age >= STALE_WAIT
      return :aging if age >= AGING_WAIT

      :fresh
    end

    def approval_wait_classes(since) = WAIT_CLASSES.fetch(approval_wait_tone(since))
  end
end
