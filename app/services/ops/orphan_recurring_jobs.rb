# frozen_string_literal: true

module Ops
  # I job rimasti in attesa su una coda che NESSUN pool di worker serve. Non ripartiranno mai e non
  # falliranno mai: nessuno li prenderà in mano, quindi nessuno segnalerà niente.
  #
  # Perché esiste (CYRA-786). Fino a CYRA-714 il giro `clear_solid_queue_finished_jobs` non aveva
  # `queue:` in config/recurring.yml e finiva su `solid_queue_recurring`, la coda che
  # SolidQueue::RecurringJob ha scritta nel codice della gemma e che nessuno dei nostri pool serve.
  # Misurato in produzione il 2026-09-06: 628 job in attesa, accodati fra il 2026-08-07 12:12 e il
  # 2026-09-02 15:12 — l'ultimo, guarda caso, poche ore dopo il commit che ha chiuso il difetto.
  # Restano lì a far sembrare enorme un arretrato che non esiste: hanno già portato fuori strada una
  # diagnosi delle prestazioni.
  #
  # Il filtro è sulla COPERTURA della coda, mai sull'età. Cancellare "i job vecchi" toccherebbe anche
  # gli arretrati veri di code vive, che invece vanno smaltiti, non buttati.
  #
  # Che di orfani non se ne creino di nuovi lo garantisce Ops::RecurringQueueCoverage (CYRA-785):
  # questa classe ripulisce il passato, quella sorveglia il futuro.
  class OrphanRecurringJobs
    # Si tocca SOLO il wrapper dei giri periodici. Un job applicativo fermo su una coda scoperta è un
    # caso diverso e recuperabile — si sposta, o si rimette un worker sulla corsia — e buttarlo
    # costerebbe lavoro vero. Qui l'errore non è simmetrico: non cancellare abbastanza si rimedia,
    # cancellare troppo no.
    ORPHAN_CLASS = "SolidQueue::RecurringJob"

    class << self
      # I job in attesa su code scoperte, come relazione su SolidQueue::ReadyExecution.
      def pending
        discovered = orphan_queues
        return SolidQueue::ReadyExecution.none if discovered.empty?

        SolidQueue::ReadyExecution
          .where(queue_name: discovered)
          .where(job_id: SolidQueue::Job.where(class_name: ORPHAN_CLASS).select(:id))
      end

      # Quanti sono, da quando e su quali code. Da guardare PRIMA di cancellare: se i numeri non sono
      # quelli attesi, il difetto non è quello che si crede e va capito prima di toccare qualcosa.
      def summary
        relation = pending

        job_ids = relation.pluck(:job_id).sort

        {
          count: job_ids.size,
          oldest_at: relation.minimum(:created_at),
          newest_at: relation.maximum(:created_at),
          queues: relation.group(:queue_name).count,
          job_ids:,
          token: token_for(job_ids)
        }
      end

      # L'impronta dell'insieme da cancellare. Il conteggio NON lo identifica: due orfani diversi
      # fanno comunque "due", quindi una conferma sul numero lascerebbe cancellare job diversi da
      # quelli letti nel report. Su questa impronta, invece, qualunque cambiamento si vede.
      def token_for(job_ids)
        return "vuoto" if job_ids.empty?

        Digest::SHA256.hexdigest(job_ids.sort.join(",")).first(12)
      end

      # Rimuove gli orfani e i job a cui appartengono; restituisce quanti ne ha tolti.
      #
      # `job_ids:` sono quelli che l'operatore ha VISTO in `summary`. Ricalcolarli qui allargherebbe
      # la cancellazione a orfani arrivati dopo la conferma: nessuno li ha guardati, e il numero
      # appena confermato diventerebbe falso.
      #
      # Cancellare il SolidQueue::Job porta via a cascata la sua riga in ready_executions (la chiave
      # esterna è `on_delete: :cascade`), ma lasciare il job senza la sua esecuzione sarebbe peggio
      # del problema: si toglie la coppia, non una metà.
      def delete!(job_ids: pending.pluck(:job_id))
        return 0 if job_ids.empty?

        SolidQueue::Job.where(id: job_ids).delete_all.tap do
          SolidQueue::ReadyExecution.where(job_id: job_ids).delete_all
        end
      end

      private

      # Le code su cui ci sono job in attesa e che nessun pool serve. Si parte da ciò che c'è DAVVERO
      # in coda, non da un elenco scritto a mano: un orfano su una coda che non abbiamo previsto è
      # esattamente il caso che vogliamo pescare.
      #
      # La copertura la decide Ops::RecurringQueueCoverage e non una sottrazione fra elenchi: Solid
      # Queue accetta `*` e `prefisso*`, e una sottrazione li tratterebbe come nomi letterali —
      # dichiarando orfani, e quindi cancellabili, i job di code perfettamente servite.
      def orphan_queues
        SolidQueue::ReadyExecution.distinct
                                  .pluck(:queue_name)
                                  .reject { |queue| Ops::RecurringQueueCoverage.covered?(queue) }
      end
    end
  end
end
