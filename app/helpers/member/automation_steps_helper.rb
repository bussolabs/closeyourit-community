# frozen_string_literal: true

module Member
  # I PASSI della lavorazione come righe della scheda Automazione: quelli soli restano soli, le
  # sequenze di tentativi consecutivi con lo stesso esito diventano una riga apribile. In fila
  # coprivano tutto il resto della scheda, e per arrivare al piano bisognava scorrerli tutti
  # (CYRA-384, CYRA-742).
  module AutomationStepsHelper
    # Da quanti tentativi consecutivi in poi la scheda li raccoglie in una riga sola (CYRA-384).
    # Sotto i tre il guadagno non c'è: nascondere due righe costringe comunque ad aprirle per leggerle,
    # e si è solo aggiunto un gesto.
    STEP_GROUP_MIN = 3

    # I passi in righe: quelli soli restano soli, e le sequenze di tentativi consecutivi con lo stesso
    # esito diventano UNA riga apribile (CYRA-384) — «19 tentativi interrotti fra 02:58 e 08:55».
    # In fila coprivano tutto il resto della scheda, e per arrivare al piano bisognava scorrerli tutti.
    #
    # `pinned_ids` sono i passi che la scheda apre d'ufficio (quello in corso, l'ultimo respinto,
    # l'ultimo guasto): dicono DOVE sta la lavorazione adesso, e chiuderli in un gruppo li
    # nasconderebbe proprio quando servono. Restano righe per conto loro.
    def automation_step_groups(attempts, pinned_ids:)
      pinned = Array(pinned_ids).compact.to_set
      attempts.chunk_while do |before, after|
        automation_outcome_key(before) == automation_outcome_key(after) && !pinned.include?(before.id) && !pinned.include?(after.id)
      end.flat_map { |run| run.size >= STEP_GROUP_MIN ? [ collapsed_group(run) ] : run.map { |a| single_group(a) } }
    end

    # Durata del tentativo, o nil se non è ancora finito. La formattazione è quella condivisa
    # (Agents::DurationsHelper#agent_duration): una sola resa delle durate in tutta l'app. Qui resta il solo
    # nil per "non è ancora finito" — la riga della timeline in quel caso omette del tutto il campo,
    # invece di stampare il trattino che agent_duration userebbe.
    def automation_duration(attempt)
      return nil if attempt.started_at.blank? || attempt.finished_at.blank?

      agent_duration(attempt.finished_at - attempt.started_at)
    end

    # Il nome della macchina che ha eseguito il passo, cliccabile verso la sua scheda (stato, attività,
    # storico e rendimento — CYRA-279): dal tentativo si arriva all'host senza ripescarlo a mano
    # nell'elenco. `agents.view` è ORG-level mentre la tab del ticket la vede chi vede il progetto:
    # senza permesso resta testo, mai un link che porta a un accesso negato.
    #
    # Un `<a>` dentro il `<summary>` del passo naviga senza aprire/chiudere il `<details>` (l'activation
    # behavior lo consuma l'elemento più interno): nessun JS, come vuole CYRA-281.
    #
    # `css` sono le classi comuni ai due rami (font e corpo), `plain_css` il SOLO colore del testo non
    # cliccabile: tenerlo fuori da `css` evita che sul link convivano due utility di colore, dove a
    # vincere sarebbe l'ordine del CSS generato e non quello scritto qui.
    def automation_host_label(host, css: nil, plain_css: nil, test_id: nil)
      data = test_id ? { test: test_id } : {}
      name = host&.hostname.presence || t("member.tickets.automation.steps.unknown_host")
      return tag.span(name, class: class_names(css, plain_css), data:) unless host && can_view_agents?

      link_to name, member_agent_path(host), class: class_names(css, "text-indigo-700 dark:text-indigo-300 hover:underline"), data:
    end

    private
    # Un gruppo raccolto: l'esito è quello del primo (dentro sono tutti uguali per costruzione), e
    # l'arco di tempo va dall'avvio del primo alla fine dell'ultimo. Un tentativo interrotto a metà
    # non ha una fine: lì l'arco si chiude sul suo avvio, invece di stampare un buco al posto dell'ora.
    def collapsed_group(run)
      { collapsed: true, attempts: run, outcome: automation_outcome(run.first),
        from: run.first.started_at, to: (run.last.finished_at || run.last.started_at) }
    end

    def single_group(attempt)
      { collapsed: false, attempts: [ attempt ], outcome: automation_outcome(attempt),
        from: attempt.started_at, to: attempt.finished_at }
    end
  end
end
