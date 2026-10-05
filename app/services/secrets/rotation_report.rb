# frozen_string_literal: true

module Secrets
  # Vista "Cosa ruotare" org-wide (CYRA-138, Fase 4 pezzo A1; copertura + età CYRA-407): sui progetti
  # VISIBILI passati raccoglie i secret con una policy di rotazione due_soon/overdue E misura quanti
  # secret sono coperti da una policy sul totale — perché "Scaduti: 0" e "nessuna policy esiste"
  # producono lo stesso zero, un falso verde. Gemello di Secrets::HealthCheck (gate secrets_audit.view).
  #
  # Query PRECARICATA in blocco (1 query + includes, indipendente dal numero di progetti): tutte le
  # variabili dei progetti passati caricate una volta, poi filtrate/ordinate in RUBY sui dati già in
  # memoria — MAI una query per-progetto in loop (guard Prosopite bloccante sui request spec). Il
  # VALORE cifrato non viene mai decifrato: qui contano solo nome, rotated_at (età del valore), policy
  # e scope [progetto, ambiente].
  class RotationReport
    # Anteprima dei secret senza regola: org-wide possono essere migliaia (1057 nel rilievo che ha
    # aperto CYRA-407), non si rende un dump. Si mostrano i più vecchi — i candidati da cui partire —
    # e il resto finisce nel conteggio residuo (#uncovered_overflow_count), esplicito, mai nascosto.
    UNCOVERED_PREVIEW_LIMIT = 50

    def initialize(projects:)
      @project_ids = projects.to_a.map(&:id)
    end

    # Variabili da ruotare (due_soon + overdue), le più urgenti in cima: overdue prima di due_soon,
    # poi per rotate_by crescente (scaduto da più tempo / in scadenza più vicina prima).
    def variables
      @variables ||= all_variables
        .select { |variable| %i[due_soon overdue].include?(variable.rotation_status) }
        .sort_by { |variable| [ variable.rotation_status == :overdue ? 0 : 1, variable.rotate_by ] }
    end

    def overdue_count
      @overdue_count ||= variables.count { |variable| variable.rotation_status == :overdue }
    end

    def due_soon_count
      @due_soon_count ||= variables.count { |variable| variable.rotation_status == :due_soon }
    end

    def any?
      variables.any?
    end

    # Denominatore della copertura: TUTTI i secret visibili, con o senza regola.
    def total_count
      all_variables.size
    end

    # Numeratore della copertura: i secret con una regola di rotazione attiva.
    def covered_count
      @covered_count ||= all_variables.count { |variable| variable.rotation_interval_days.present? }
    end

    # Secret senza alcuna regola di rotazione.
    def uncovered_count
      total_count - covered_count
    end

    # Esiste almeno una regola configurata? A false la pagina NON mostra "zero scadenze" come un via
    # libera: dice che la funzione non è attiva e porta ad attivarla (Scenario 1 del ticket).
    def any_policy?
      covered_count.positive?
    end

    # Tono semantico del chip Copertura (mappato a un colore da StatLabelComponent). Vault VUOTO
    # (total zero, "0 / 0") → :neutral, NON :red: senza alcun secret non c'è nessun falso verde da
    # segnalare, e un "0 / 0" rosso contraddirebbe lo stato neutro del corpo. Con secret presenti:
    # zero copertura → :red (il falso verde smascherato), parziale → :amber, piena → :emerald.
    def coverage_tone
      return :neutral if total_count.zero?
      return :red if covered_count.zero?
      return :amber if uncovered_count.positive?

      :emerald
    end

    # Secret senza regola, il VALORE più vecchio in cima (rotated_at crescente; età sconosciuta in
    # fondo, ordinata per nome per stabilità): l'ordine da cui partire per attivare la rotazione,
    # soprattutto in produzione. Cap a UNCOVERED_PREVIEW_LIMIT.
    def uncovered_preview
      uncovered_variables.first(UNCOVERED_PREVIEW_LIMIT)
    end

    # Quanti secret senza regola NON entrano nell'anteprima (0 = mostrati tutti).
    def uncovered_overflow_count
      [ uncovered_count - UNCOVERED_PREVIEW_LIMIT, 0 ].max
    end

    private

    def uncovered_variables
      @uncovered_variables ||= all_variables
        .reject { |variable| variable.rotation_interval_days.present? }
        .sort_by { |variable| variable.rotated_at ? [ 0, variable.rotated_at ] : [ 1, variable.name.to_s ] }
    end

    # Tutte le variabili dei SOLI progetti passati (scoping anti-BOLA): fonte unica sia della copertura
    # sia delle due liste (da ruotare / senza regola). 1 query + includes (project/environment per il
    # rendering), non una per progetto.
    def all_variables
      @all_variables ||= ::Secrets::Variable.where(project_id: @project_ids)
        .includes(:project, :environment)
        .to_a
    end
  end
end
