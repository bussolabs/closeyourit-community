# frozen_string_literal: true

require "rails_helper"

# CYRA-786 — i giri accodati su una coda che nessun pool serve restano in attesa per sempre. Al
# 2026-09-06 in produzione ce n'erano 628, accodati fra il 2026-08-07 e il 2026-09-02, residuo del
# difetto chiuso da CYRA-714. Non fanno danno, ma falsano ogni lettura dello stato della lavorazione:
# sembra un arretrato enorme quando invece è tutto fermo.
RSpec.describe Ops::OrphanRecurringJobs, type: :service do
  # Creare il Job basta: Solid Queue gli prepara da sé la riga in solid_queue_ready_executions. La
  # data la scriviamo dopo, perché è quella che l'indagine ha letto in produzione e non va inventata
  # a mano su due tabelle scollegate.
  def enqueue(queue_name:, class_name: "SolidQueue::RecurringJob", created_at: 1.day.ago)
    job = SolidQueue::Job.create!(queue_name:, class_name:, active_job_id: SecureRandom.uuid)
    job.update_columns(created_at:)
    job.ready_execution.update_columns(created_at:)
    job
  end

  describe ".pending" do
    it "conta solo i job in attesa su code che nessun pool serve" do
      enqueue(queue_name: "solid_queue_recurring")
      enqueue(queue_name: "solid_queue_recurring")
      enqueue(queue_name: "batch", class_name: "Usage::PruneJob")

      expect(described_class.pending.count).to eq(2)
    end

    it "non tocca un job in attesa su una coda servita, per quanto vecchio" do
      enqueue(queue_name: "batch", class_name: "Usage::PruneJob", created_at: 3.months.ago)

      expect(described_class.pending).to be_empty
    end

    # Il filtro è sulla COPERTURA della coda, non sull'età: un orfano appena accodato è comunque un
    # orfano, e un job vecchio su una coda viva è solo un arretrato.
    it "segnala un orfano anche se accodato adesso" do
      enqueue(queue_name: "solid_queue_recurring", created_at: Time.current)

      expect(described_class.pending.count).to eq(1)
    end
  end

  describe "confini della selezione" do
    # Il ticket parla dei giri periodici rimasti fermi. Un job APPLICATIVO su una coda scoperta è un
    # caso diverso: si recupera spostandolo o riattivando la corsia, non si butta. Restringere è la
    # scelta prudente, perché qui l'errore si paga in lavoro perso.
    it "non tocca un job applicativo, nemmeno su una coda scoperta" do
      applicativo = enqueue(queue_name: "solid_queue_recurring", class_name: "Usage::PruneJob")

      expect(described_class.pending).to be_empty
      described_class.delete!
      expect(SolidQueue::Job.exists?(applicativo.id)).to be(true)
    end

    # Solid Queue serve TUTTE le code quando un pool dichiara "*": lì non esiste nessun orfano, e
    # cancellare sarebbe distruggere lavoro che sta per partire.
    it "col jolly nei worker non considera orfano nessuno" do
      enqueue(queue_name: "solid_queue_recurring")
      pool = SolidQueue::Configuration::Process.new(:worker, { queues: [ "*" ] })
      allow(SolidQueue::Configuration).to receive(:new).and_return(
        instance_double(SolidQueue::Configuration, configured_processes: [ pool ])
      )

      expect(described_class.pending).to be_empty
    end
  end

  describe ".summary" do
    it "riassume quanti sono e da quando, per poterlo scrivere prima di cancellare" do
      enqueue(queue_name: "solid_queue_recurring", created_at: Time.zone.parse("2026-08-07 12:12"))
      enqueue(queue_name: "solid_queue_recurring", created_at: Time.zone.parse("2026-09-02 15:12"))

      riassunto = described_class.summary

      expect(riassunto[:count]).to eq(2)
      expect(riassunto[:oldest_at]).to eq(Time.zone.parse("2026-08-07 12:12"))
      expect(riassunto[:newest_at]).to eq(Time.zone.parse("2026-09-02 15:12"))
      expect(riassunto[:queues]).to eq({ "solid_queue_recurring" => 2 })
    end

    it "su una lavorazione pulita non riassume niente" do
      expect(described_class.summary).to eq({ count: 0, oldest_at: nil, newest_at: nil, queues: {}, job_ids: [], token: "vuoto" })
    end
  end

  describe ".delete!" do
    it "rimuove gli orfani e i loro job, e restituisce quanti ne ha tolti" do
      enqueue(queue_name: "solid_queue_recurring")
      enqueue(queue_name: "solid_queue_recurring")

      expect { expect(described_class.delete!).to eq(2) }
        .to change { SolidQueue::ReadyExecution.count }.by(-2)
        .and change { SolidQueue::Job.count }.by(-2)
    end

    it "non tocca i job delle code servite" do
      vivo = enqueue(queue_name: "batch", class_name: "Usage::PruneJob")
      enqueue(queue_name: "solid_queue_recurring")

      described_class.delete!

      expect(SolidQueue::Job.exists?(vivo.id)).to be(true)
      expect(SolidQueue::ReadyExecution.where(job_id: vivo.id)).to exist
    end

    it "su una lavorazione pulita non cancella niente" do
      enqueue(queue_name: "batch", class_name: "Usage::PruneJob")

      expect { expect(described_class.delete!).to eq(0) }.not_to change { SolidQueue::Job.count }
    end

    # Fra il conteggio che l'operatore conferma e la cancellazione passa del tempo. Un orfano arrivato
    # nel frattempo non è stato guardato da nessuno: cancellarlo sarebbe una scommessa, e renderebbe
    # bugiardo il numero appena confermato.
    it "cancella SOLO gli id passati, non quelli arrivati dopo" do
      visto = enqueue(queue_name: "solid_queue_recurring")
      riassunto = described_class.summary
      arrivato_dopo = enqueue(queue_name: "solid_queue_recurring")

      expect(described_class.delete!(job_ids: riassunto[:job_ids])).to eq(1)
      expect(SolidQueue::Job.exists?(visto.id)).to be(false)
      expect(SolidQueue::Job.exists?(arrivato_dopo.id)).to be(true)
    end
  end

  describe ".summary" do
    it "porta con sé gli id, così la conferma vale su quelli e non su un ricalcolo" do
      job = enqueue(queue_name: "solid_queue_recurring")

      expect(described_class.summary[:job_ids]).to eq([ job.id ])
    end

    # Il conteggio non identifica l'insieme: due orfani diversi sono comunque "due". La conferma deve
    # valere su CHI si cancella, non su quanti.
    it "l'impronta cambia se cambiano gli id, anche a parità di numero" do
      primo = enqueue(queue_name: "solid_queue_recurring")
      impronta_prima = described_class.summary[:token]

      SolidQueue::Job.find(primo.id).destroy!
      enqueue(queue_name: "solid_queue_recurring")
      riassunto_dopo = described_class.summary

      expect(riassunto_dopo[:count]).to eq(1)
      expect(riassunto_dopo[:token]).not_to eq(impronta_prima)
    end
  end
end
