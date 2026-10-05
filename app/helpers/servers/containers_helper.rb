# frozen_string_literal: true

module Servers
  # Quello che GIRA sopra la macchina: i container e la loro salute, gli stati delle connessioni al
  # database, le righe del registro di sistema e l'esito dei controlli del disco. Tutto ciò che
  # l'agent riporta col nome tecnico e va scritto a parole (CYRA-742).
  module ContainersHelper
    # CYRA-515 — i container attualmente in riavvio continuo su questa macchina, indicizzati per nome
    # per marcare la riga giusta della tabella. È lo STESSO oggetto su cui è scattato l'avviso
    # (Servers::Ingest::Record), non un ricalcolo: l'avviso nomina il container, la pagina lo conferma.
    # Nessun riavvio in corso → hash vuoto, la tabella resta com'era.
    def server_container_restarts(host)
      outage = host&.container_restart_outage
      return {} unless outage.is_a?(Hash)

      Array(outage["containers"]).index_by { |container| container["name"] }
    end

    CONTAINER_HEALTH_COLORS = { "healthy" => :emerald, "unhealthy" => :red, "starting" => :amber, "none" => :gray }.freeze
    def server_container_health_color(health) = CONTAINER_HEALTH_COLORS.fetch(health.to_s, :gray)

    # CYRA-464 — «none» sembrava un allarme e significa soltanto che per quel programma non è previsto
    # nessun controllo di salute. Si scrive a parole, in grigio, come le altre assenze.
    def server_container_health_label(health)
      t("member.servers.show.health.#{health}", default: health.to_s)
    end

    # CYRA-467 — gli stati delle connessioni al database arrivano col nome tecnico di PostgreSQL, che
    # nemmeno molti addetti ai lavori leggono al volo — e `idle_in_transaction` è il dato più
    # azionabile del blocco (una transazione lasciata aperta blocca gli altri). Si scrive a parole, col
    # nome tecnico come secondario: chi lo cerca lo trova, chi non lo conosce capisce lo stesso.
    # Uno stato che non conosciamo si mostra com'è arrivato.
    def server_connection_state_label(state)
      t("member.servers.show.connection_states.#{state}", default: state.to_s)
    end

    # Il nome porta in coda il codice della versione, quaranta caratteri che mangiavano la riga: si
    # mostra a sette, e il nome completo resta nel tooltip. Il codice si riconosce dalla forma
    # (esadecimale lungo), non dalla posizione: i nomi cambiano forma fra un orchestratore e l'altro.
    CONTAINER_SHA = /\b[0-9a-f]{12,}\b/i

    def server_container_name(name)
      name.to_s.gsub(CONTAINER_SHA) { |sha| sha[0, 7] }
    end

    # L'immagine si taglia a SINISTRA: la parte che identifica il programma è la coda
    # (`…/bussolabs/closeyourit:v1.2.3`), non il registro da cui viene.
    def server_container_image(image, max: 46)
      value = image.to_s
      return "—" if value.blank?
      return value if value.length <= max

      "…#{value[-(max - 1)..]}"
    end

    def server_smart_color(status)
      status.to_s.casecmp?("PASSED") ? :emerald : :red
    end

    # Pillola priority journald (syslog 0..7). Nello stream arrivano solo <= 3; 0-2 (emerg/alert/crit)
    # rosso, 3 (err) ambra, il resto neutro. Classi LITERAL (no interpolazione Tailwind).
    def server_journal_priority_class(priority)
      case priority.to_i
      when 0, 1, 2 then "bg-red-50 dark:bg-red-500/15 text-red-700 dark:text-red-300"
      when 3 then "bg-amber-50 dark:bg-amber-500/15 text-amber-700 dark:text-amber-300"
      else "bg-stone-100 dark:bg-zinc-800 text-gray-600 dark:text-zinc-400"
      end
    end

    def server_journal_priority_label(priority)
      t("member.servers.show.journal_priority.#{priority.to_i}", default: priority.to_i.to_s)
    end
  end
end
