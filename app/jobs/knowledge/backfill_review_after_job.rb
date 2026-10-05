# frozen_string_literal: true

module Knowledge
  # CYRA-768 — dà una data di rilettura al parco esistente (coda :batch). Lancio manuale:
  #   bin/rails runner 'Knowledge::BackfillReviewAfterJob.perform_later'
  #
  # NON è un semplice «applica la finestra del tipo»: quasi tutte le pagine esistenti sono più
  # vecchie della loro finestra, e la data naturale cadrebbe nel passato — la coda nascerebbe con
  # centinaia di righe scadute nello stesso istante, cioè illeggibile, cioè non letta. Chi risulta
  # già scaduto viene quindi SPALMATO sui prossimi REVIEW_BACKFILL_SPREAD_DAYS giorni, dalla pagina
  # più stantia in avanti: una manciata al giorno, che è il ritmo a cui una coda si smaltisce.
  #
  # Idempotente: guarda solo le pagine senza data. Chi ne ha già una — perché accettata, riscritta o
  # confermata dopo il rilascio — non viene toccato, quindi un secondo giro non sposta niente.
  # update_columns e non update!: la data di rilettura non è una modifica della pagina, e toccare
  # `updated_at` riordinerebbe ogni elenco facendo sembrare aggiornato tutto l'archivio.
  class BackfillReviewAfterJob < ApplicationJob
    queue_as :batch

    # Quante righe si caricano per volta: gli id arrivano tutti insieme (leggeri), i record no.
    BATCH_SIZE = 200

    def perform
      spread = 0

      each_pending do |page|
        natural = Knowledge::ReviewSchedule.next_for(kind: page.kind, from: page.reviewed_at || page.updated_at)
        next if natural.nil? # difesa: lo scope tiene già fuori i tipi che non scadono

        if natural > Time.current
          page.update_columns(review_after: natural)
        else
          page.update_columns(review_after: staggered(spread))
          spread += 1
        end
      end
    end

    private

    # NON `find_each`: quello SCARTA l'ordinamento chiesto e impone il proprio sulla chiave primaria,
    # che qui è un uuid — l'ordine per anzianità sparirebbe in silenzio e la coda si aprirebbe con
    # pagine a caso invece che con le più stantie. Gli id si prendono in ordine (una colonna sola,
    # leggera anche su tutto il parco) e le righe si caricano a blocchi, tenendo quell'ordine.
    def each_pending(&block)
      pending.pluck(:id).each_slice(BATCH_SIZE) do |ids|
        by_id = Knowledge::Page.where(id: ids).index_by(&:id)
        ids.each { |id| block.call(by_id[id]) if by_id[id] }
      end
    end

    # Le pagine senza data, dei soli tipi che scadono, e solo quelle già entrate nella conoscenza:
    # una proposta in revisione (o scartata) non ha un conto da far partire — glielo mette chi la
    # accetta. Ordinate dalla più stantia, così le prime a tornare in coda sono le più sospette.
    def pending
      Knowledge::Page.live
                     .where(review_after: nil, kind: Knowledge::ReviewSchedule.expiring_kinds)
                     .order(Arel.sql("COALESCE(reviewed_at, updated_at) ASC"))
    end

    # Domani più uno scaglione: mai oggi, altrimenti la pagina risulterebbe da rileggere nell'istante
    # stesso in cui il backfill le assegna la data.
    def staggered(position)
      Time.current.beginning_of_day + 1.day + (position % Knowledge::Constants::REVIEW_BACKFILL_SPREAD_DAYS).days
    end
  end
end
