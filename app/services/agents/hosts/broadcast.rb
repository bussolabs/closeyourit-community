# frozen_string_literal: true

module Agents
  module Hosts
    # CYRA-823 — il segnale che l'attività di un agente è cambiata, per chi ha la sua scheda aperta.
    # I nomi-stream vengono SOLO da Realtime::Streams (isolamento tenant nel nome).
    #
    # NON spedisce HTML, e non è una precauzione generica: `agents.view` è un permesso di
    # organizzazione, ma i ticket che l'agente sta lavorando si vedono per PROGETTO. Due membri della
    # stessa organizzazione davanti alla stessa scheda devono leggere due pagine diverse — uno con i
    # titoli, l'altro con i soli codici — e una pagina renderizzata qui non saprebbe per chi è.
    # Viaggia quindi il solo «quel pezzo è vecchio»: ognuno ri-chiede il frame con la propria
    # sessione e il filtro lo rifà il controller.
    #
    # Il bersaglio è il FRAME dell'attività, non la pagina: un page-refresh farebbe ricalcolare al
    # server anche rendimento e storico — la parte cara — a ogni battito dell'agente.
    module Broadcast
      # Il nome del frame bersaglio vive QUI, dove nasce il segnale, e la pagina lo legge da qui
      # (Member::AgentsController): in due posti diversi, un rinominio da un lato solo manderebbe il
      # segnale a un frame che non esiste più — e la scheda smetterebbe di aggiornarsi in silenzio,
      # senza nessun errore da nessuna parte.
      ACTIVITY_FRAME = "host-activity"

      module_function

      def activity(host)
        Realtime::ThrottledRefresh.call(Realtime::Streams.agent_host(host), frame: ACTIVITY_FRAME)
      end
    end
  end
end
