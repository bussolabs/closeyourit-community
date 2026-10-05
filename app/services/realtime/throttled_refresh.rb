# frozen_string_literal: true

module Realtime
  # Page-refresh Turbo throttlato per stream, con LEADING immediato e un solo TRAILING in volo.
  # Estratto da Errors/Metrics/Logs::Broadcast, dove viveva triplicato identico.
  #
  # Il leading resta com'era: il primo evento della finestra fa il refresh subito, così la UI non
  # resta ferma all'inizio del burst. Cambia il trailing, e cambia per una ragione misurata: prima il
  # suo lock scadeva insieme alla finestra (1 secondo), quindi sotto un burst prolungato si accodava
  # un job al secondo per stream — di per sé il comportamento progettato, ma il 2026-07-29 ha
  # significato 94 job identici in coda sullo stesso stream, tutti a chiedere lo stesso identico
  # refresh. Ora il lock dura finché il job pendente non ha girato: da lì in poi ne esiste **uno solo
  # per stream**, e i successivi eventi del burst non ne aggiungono altri.
  #
  # Perché è sicuro tenerne uno solo: il refresh non trasporta stato, dice "ricarica" e basta. Un
  # viewer che ricarica dopo l'ultimo evento del burst vede lo stato finale, esattamente come se
  # avesse ricaricato 94 volte.
  module ThrottledRefresh
    # Rete di sicurezza del lock trailing: se il worker è giù o il job muore prima dell'`ensure`, il
    # lock non deve restare appeso per sempre bloccando ogni refresh futuro di quello stream.
    # Generoso rispetto alla finestra (che è nell'ordine del secondo) perché il costo di un lock
    # scaduto troppo presto è un job in più, quello di uno scaduto troppo tardi è una UI ferma.
    TAIL_LOCK_TTL = 1.minute

    module_function

    # `frame:` (CYRA-823) restringe il segnale a UN pezzo di pagina invece che alla pagina intera:
    # chi lo riceve ricarica quel frame e basta. Serve dove la pagina è fatta di parti che cambiano a
    # ritmi diversi — l'attività di un agente cambia a ogni battito, il suo storico quasi mai — e un
    # page-refresh farebbe rifare al server anche il lavoro caro che nessuno ha chiesto.
    # Senza `frame:` il comportamento non cambia di una virgola: page-refresh, come sempre.
    def call(stream, frame: nil)
      window = Monitoring::Constants::BROADCAST_THROTTLE
      # A trailing job this process scheduled covers every event until it runs, and it cannot run
      # before `window`: no need to ask the shared cache again meanwhile (CYRA-890).
      return if Ops::LocalGate.held?(tail_key(stream))

      if Rails.cache.write(leading_key(stream), true, unless_exist: true, expires_in: window)
        broadcast(stream, frame)
      elsif Rails.cache.write(tail_key(stream), true, unless_exist: true, expires_in: TAIL_LOCK_TTL)
        Ops::LocalGate.hold(tail_key(stream), expires_in: window)
        # Senza frame il job si accoda con il solo stream, esattamente come prima: la coda non porta
        # un argomento vuoto e i lavori già in volo al momento del rilascio restano validi.
        Realtime::BroadcastRefreshJob.set(wait: window).perform_later(*[ stream, frame.presence ].compact)
      end
    end

    # Il messaggio è un'azione turbo-stream SENZA contenuto: `<turbo-stream action="refresh_frame"
    # target="...">`. È la ragione per cui può viaggiare su uno stream condiviso da persone con
    # visibilità diverse — non trasporta niente da vedere, dice solo «quel pezzo è vecchio».
    def broadcast(stream, frame = nil)
      return Turbo::StreamsChannel.broadcast_refresh_to(stream) if frame.blank?

      Turbo::StreamsChannel.broadcast_action_to(stream, action: :refresh_frame, target: frame, render: false)
    end

    # Chiavi derivate dallo STREAM e non passate dal chiamante: il job deve poter rilasciare il lock
    # sapendo solo su cosa ha fatto il broadcast. Lo stream è già unico e tenant-prefissato
    # (Realtime::Streams), quindi è la chiave naturale.
    def leading_key(stream) = "realtime:refresh:#{stream}"
    def tail_key(stream) = "realtime:refresh:#{stream}:tail"
  end
end
