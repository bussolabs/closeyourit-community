# frozen_string_literal: true

module Agents
  # Costanti del dominio agent host (rules/constants.md): le definizioni arrivano da
  # closeyourit-automator via API e qui stanno le soglie con cui si decide che una lavorazione è
  # ferma, abbandonata o che una macchina sta buttando via il lavoro.
  module Constants
    # Token org-scoped usato dal daemon soltanto per registrare un'installazione.
    TOKEN_PREFIX = "cyi_a_"
    # Credenziale dedicata e revocabile di una singola installazione closeyourit-automator.
    HOST_TOKEN_PREFIX = "cyi_ah_"
    # Storico run: potato oltre questa età (le run vecchie non servono, la definizione resta).
    RUN_RETENTION_DAYS = 30

    # Grazia prima di dichiarare FERMA una lavorazione la cui prenotazione è scaduta (CYRA-201). Serve a
    # non uccidere una consegna ancora in volo: l'host può stare rinnovando il lease o avere il PUT del
    # risultato già partito quando la riga risulta scaduta. Oltre la grazia, senza consegna registrata,
    # la lavorazione è morta e va chiusa — altrimenti resta "in corso" per sempre e può far scambiare un
    # orfano per un tentativo già in corso, bloccando i claim successivi sullo stesso ticket.
    ATTEMPT_STALE_GRACE = 5.minutes

    # Quante volte la revisione incrociata può bocciare la STESSA fase prima che la lavorazione si fermi
    # e chiami una persona (CYRA-218). Senza tetto il ciclo è infinito per costruzione: la prontezza di una
    # fase è un predicato sui timestamp (`triaged_at? && planned_at.nil?` per il planner), che una bocciatura
    # non muove — quindi la fase resta reclamabile e si riprova, uguale, per sempre. Due tentativi sono lo
    # stesso budget dei chiarimenti: se due giri di revisione non convergono, il terzo non converge da solo.
    PHASE_REVIEW_LIMIT = 2
    # CYRA-598 — quante volte di fila una consegna puo' dire «non sono riuscito a guardare» prima che
    # la lavorazione chiami una persona. E' un tetto SUO, separato da quello dei tentativi bocciati:
    # quella consegna e' un tentativo APPROVATO — il formato e' valido, il contenuto e' onesto — e il
    # tetto delle bocciature non la vedrebbe mai. Tre e non due: un servizio esterno che non risponde
    # tre volte di fila non e' piu' un inciampo.
    PHASE_UNREACHABLE_LIMIT = 3

    # Finestra di osservazione dell'allarme "lavorazioni bloccate" (CYRA-212, Scenario 2): con host attivi,
    # se per questo intervallo il sistema chiude tentativi senza mai concluderne uno con successo, gira a
    # vuoto e va segnalato. Pari al TTL di esecuzione delle fasi (PhaseProfile 3600s): sotto il tetto un
    # tentativo può essere ancora legittimamente in volo, quindi si guarda l'assenza di PROGRESSO, non la
    # sola durata.
    STALL_WINDOW = 1.hour

    # CYRA-673 — dopo quanto una lavorazione senza piu' segni di vita smette di tenere bloccato lo
    # stato e il corpo del ticket. Non basta guardare lease e tentativi: fra una fase e l'altra il
    # lease e' rilasciato e i tentativi sono tutti conclusi, eppure la lavorazione e' viva. A
    # distinguere la pausa dall'abbandono c'e' solo il tempo.
    # Un giorno intero e' largo di proposito: copre le pause lunghe e le notti, e lascia comunque
    # cadere gli abbandoni veri, che si misurano in giorni (sei ticket fermi dal 23 al 27 agosto).
    WORKFLOW_ABANDONED_AFTER = 24.hours

    # Motivo di fallimento riportato dalla macchina (CYRA-282): tetto alla lunghezza del testo scritto su
    # `agents_attempts.failure_reason`. L'endpoint è pubblico (token host) e il motivo può portare un
    # traceback: si tronca a un valore leggibile invece di ingoiare payload arbitrari nell'audit.
    FAILURE_REASON_MAX = 5_000

    # Allarme "una macchina butta via il lavoro" (CYRA-282): a differenza di agents_stalled (org-scoped,
    # zero progressi) questo è PER-HOST sulla QUOTA di fallimenti. Il caso reale — una delle due macchine
    # con l'88% dei tentativi falliti mentre l'altra lavorava — non scatterebbe l'allarme org, che tace se
    # anche un solo host progredisce. Finestra di osservazione, quota minima di fallimenti e volume minimo
    # sotto cui la quota non è significativa (1 fallito su 1 è 100% ma non dice niente).
    HOST_FAILURE_WINDOW = 6.hours
    HOST_FAILURE_RATIO = 0.5
    HOST_FAILURE_MIN = 5

    # Allarme "una macchina è ferma" (CYRA-450): un host che ha superato il suo intervallo atteso (offline)
    # e per di più tace da oltre questa soglia è "fermo" (stale) — riga in allarme + avviso. È il pavimento
    # di grazia anti-rumore: un riavvio breve rientra prima di far scattare l'allarme (il Rischio del ticket).
    # Distinto dall'offline nudo (interval+grace per-host): un host può essere appena offline ma non ancora
    # fermo. Indipendente dall'intervallo per-host, così anche una macchina con cadenza lenta viene comunque
    # segnalata quando muore per davvero.
    HOST_STALE_AFTER = 15.minutes
  end
end
