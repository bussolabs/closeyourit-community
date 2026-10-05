# frozen_string_literal: true

module Alerting
  # CYRA-458: la soglia d'allarme EFFETTIVA di ogni metrica di occupazione (cpu/mem/disco) per gli host di
  # un'org, così le viste dei server possono affiancare al numero il limite oltre cui scatta l'avviso — il
  # riferimento che oggi vive solo nelle regole di alerting e nell'area server non è mai nominato.
  #
  # Precedenza (risposta al ticket): la soglia impostata sulla SINGOLA macchina vince; altrimenti il "valore
  # di partenza" è quello delle regole org — la soglia PIÙ BASSA fra le regole abilitate per quella metrica,
  # cioè la prima a far scattare l'avviso (coerente con Alerting::Evaluate#server_threshold_match?, che
  # scatta appena il valore raggiunge una soglia). Nessuna regola né override → nil (limite sconosciuto).
  #
  # Il set org si calcola UNA volta (.for) e si riusa per ogni host (#for_host, in memoria): la fleet index
  # non fa una query per riga.
  class ServerThresholds
    # metrica (chiave UI) → event_type della regola a soglia. Stesse tre di Servers::Host::THRESHOLD_COLUMNS.
    METRICS = { cpu: "server_cpu", mem: "server_mem", disk: "server_disk" }.freeze

    def self.for(organization)
      # UNA query aggregata (no N+1 / Prosopite-safe): il minimo per metrica in un solo GROUP BY. Le chiavi
      # del group su un enum sono i valori grezzi del DB → normalizzate al nome dell'evento (event_types.invert).
      event_to_name = Alerting::Rule.event_types.invert
      mins = Alerting::Rule.enabled
                           .where(organization_id: organization.id, event_type: METRICS.values)
                           .group(:event_type).minimum(:threshold)
                           .transform_keys { |key| key.is_a?(String) ? key : event_to_name[key] }
      org_defaults = METRICS.transform_values { |event_type| mins[event_type] }
      new(org_defaults)
    end

    def initialize(org_defaults)
      @org_defaults = org_defaults
    end

    # { cpu:, mem:, disk: } con la soglia effettiva: override per-macchina || soglia org || nil.
    def for_host(host)
      METRICS.keys.index_with do |metric|
        host.public_send("#{metric}_threshold") || @org_defaults[metric]
      end
    end
  end
end
