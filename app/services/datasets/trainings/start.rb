# frozen_string_literal: true

module Datasets
  module Trainings
    # Avvio di un addestramento: le condizioni per partire (righe di esempio a sufficienza, servizio
    # collegato, nessun altro addestramento in corso sullo stesso dataset) + la creazione atomica del
    # record e l'accodamento del lavoro. L'esecuzione vera è Datasets::Trainings::Run, dentro TrainJob.
    #
    # CYRA-647: la regola vive QUI e non nei controller perché i canali sono due (la pagina e la CLI) e
    # una regola scritta due volte prima o poi diverge — proprio quella che protegge dal doppio costo.
    # Il permesso resta al chiamante: è autorizzazione, non dominio.
    class Start < ApplicationService
      def initialize(dataset:, actor:)
        @dataset = dataset
        @actor = actor
      end

      def call
        return fail_with(:not_enough, "R422-DATASET-004") if too_few_rows?

        training = create_training
        # nil = un altro addestramento è già pending/running sul dataset.
        return fail_with(:already_running, "R409-DATASET-001", status: :conflict) if training.nil?

        enqueue(training)
        Result.ok(training)
      end

      private

      def too_few_rows?
        @dataset.rows.purpose_sample.count < Datasets::Constants::MIN_SAMPLE_ROWS
      end

      # CYRA-246: un addestramento occupa a lungo la corsia AI (fino a ~un'ora). Niente doppioni sullo
      # stesso dataset finché quello in corso non finisce. Il controllo "esiste già?" e la creazione
      # devono essere ATOMICI: senza lock due richieste ravvicinate passano entrambe il controllo e
      # creano due addestramenti — due volte il costo. with_lock serializza sulla riga del dataset.
      def create_training
        @dataset.with_lock do
          # CYRA-791: prima di rifiutare, si chiude ciò che è morto senza dirlo. Un addestramento ucciso
          # insieme al processo (deploy interrotto, worker terminato) non passa da nessun `rescue` e
          # resta pending/running per sempre: la riga qui sotto lo scambiava per un lavoro in corso e
          # bloccava OGNI avvio futuro su questo insieme di dati. Il recupero sta QUI, sulla richiesta,
          # e non solo nel giro periodico: quel giro vive nello stesso motore dei lavori che è appena
          # morto, quindi proprio nello scenario del guasto potrebbe non partire. Dentro il lock del
          # dataset, così la chiusura e il nuovo avvio sono un atto solo.
          Datasets::Trainings::MarkStale.call(dataset: @dataset)
          next nil if @dataset.trainings.unfinished.exists?

          @dataset.trainings.create!(created_by: @actor, status: :pending)
        end
      end

      # L'accodamento sta FUORI dal lock perché il job non deve partire prima del commit
      # (enqueue_after_transaction_commit è false); se fallisce, l'addestramento appena creato viene
      # rimosso, così un pending orfano non blocca ogni avvio futuro.
      def enqueue(training)
        Datasets::TrainJob.perform_later(training)
      rescue StandardError
        training.destroy
        raise
      end

      def fail_with(key, code, status: :unprocessable_content)
        Result.err(AppError.new(I18n.t("datasets.errors.#{key}"), code: code, status: status))
      end
    end
  end
end
