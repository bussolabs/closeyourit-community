# frozen_string_literal: true

require "rails_helper"

# CYRA-713 — la politica di ritentativo che tutti i lavori in background ereditano. Il job di prova
# è definito qui e non pescato dal dominio di proposito: ciò che si misura è ApplicationJob, non il
# lavoro che ci gira dentro.
RSpec.describe ApplicationJob do
  include ActiveJob::TestHelper

  before do
    stub_const("ProbeJob", Class.new(described_class) do
      queue_as :default

      # L'errore lo sceglie l'esempio; il contatore dice quante volte il lavoro è stato davvero
      # eseguito, che è il numero che questa lavorazione tiene sotto controllo.
      class << self
        attr_accessor :error, :runs
      end
      self.runs = 0

      def perform(_marker)
        self.class.runs += 1
        raise self.class.error
      end
    end)
  end

  def run_with(error)
    ProbeJob.error = error
    ProbeJob.perform_now("x")
  end

  describe "guasti che non guariscono da soli" do
    # Fallisce, non viene scartato: un difetto va visto. Scartarlo lascerebbe il lavoro nell'elenco
    # di quelli finiti bene, e nessuno saprebbe che non è successo niente.
    it "un difetto del programma fallisce subito, senza ritentativi" do
      expect { run_with(NoMethodError.new("undefined method `foo'")) }.to raise_error(NoMethodError)

      expect(ProbeJob.runs).to eq(1)
      expect(enqueued_jobs).to be_empty
    end

    it "un record che non passa le validazioni fallisce subito" do
      error = ActiveRecord::RecordInvalid.new(Ticketing::Ticket.new)

      expect { run_with(error) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(enqueued_jobs).to be_empty
    end

    it "un errore di dominio definitivo fallisce subito" do
      expect { run_with(AppError.new("testo vuoto", code: "R422-AI-002")) }.to raise_error(AppError)

      expect(enqueued_jobs).to be_empty
    end
  end

  describe "guasti passeggeri" do
    it "un timeout di rete viene ritentato" do
      expect { run_with(Net::ReadTimeout.new) }.not_to raise_error

      expect(enqueued_jobs.size).to eq(1)
      expect(enqueued_jobs.first["job_class"]).to eq("ProbeJob")
    end

    it "la contesa sul database viene ritentata" do
      expect { run_with(ActiveRecord::Deadlocked.new) }.not_to raise_error

      expect(enqueued_jobs.size).to eq(1)
    end

    it "il fornitore caduto viene ritentato" do
      expect { run_with(AppError.new("giù", code: "R502-AI-001", status: :bad_gateway)) }.not_to raise_error

      expect(enqueued_jobs.size).to eq(1)
    end

    # Il conto dei tentativi non cambia rispetto a prima: cambia solo che cosa ci finisce dentro.
    it "si ferma dopo i tentativi previsti e allora fallisce davvero" do
      ProbeJob.error = Net::ReadTimeout.new
      ProbeJob.perform_later("x")

      # A mano quello che farebbe il motore delle code: ogni giro consuma il lavoro in attesa e il
      # ritentativo torna in coda. All'ultimo l'errore esce, così il lavoro finisce fra i falliti.
      (described_class::MAX_ATTEMPTS - 1).times { ActiveJob::Base.execute(enqueued_jobs.shift) }
      expect { ActiveJob::Base.execute(enqueued_jobs.shift) }.to raise_error(Net::ReadTimeout)

      expect(ProbeJob.runs).to eq(described_class::MAX_ATTEMPTS)
      expect(enqueued_jobs).to be_empty
    end
  end

  describe "record sparito fra l'accodamento e l'esecuzione" do
    it "viene scartato invece di essere ritentato all'infinito" do
      # Va costruito dentro un rescue: il messaggio se lo prende dall'errore in corso.
      deserialization_error = begin
        raise ActiveRecord::RecordNotFound
      rescue ActiveRecord::RecordNotFound
        ActiveJob::DeserializationError.new
      end

      expect { run_with(deserialization_error) }.not_to raise_error
      expect(enqueued_jobs).to be_empty
    end
  end
end
