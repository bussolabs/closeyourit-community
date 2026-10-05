# frozen_string_literal: true

module Datasets
  module Trainings
    # Orchestrazione del training: dalle righe etichettate (sample) genera un prompt ottimizzato con un
    # loop iterativo (build → evaluate → refine sugli errori), tenendo il prompt con accuratezza migliore.
    # Salva prompt + metriche sul record Datasets::Training e marca il dataset `trained`. Errori (gateway
    # giù, dati insufficienti) → training `failed` + Result.err. Eseguito da Datasets::TrainJob.
    class Run < ApplicationService
      def initialize(training:, client: nil)
        @training = training
        @dataset = training.dataset
        @client = client
      end

      def call
        # Idempotenza: SolidQueue è at-least-once. Una riconsegna non deve rifare il loop LLM (ri-billing)
        # né riportare a running un training già done/failed.
        return Result.ok(@training) unless @training.status_pending?

        # Interruttore del god: il training muore subito e VISIBILMENTE (propagate → finish_err!),
        # invece di restare pending in attesa di un provider che non chiameremo mai.
        if ::Ai::Feature.disabled?(:dataset_predictions)
          return propagate(Result.err(::Ai::Feature.disabled_error(:dataset_predictions)))
        end

        # La presa in carico è ATOMICA (CYRA-791): fra il controllo qui sopra e questa riga può
        # infilarsi un'altra consegna dello stesso lavoro — Solid Queue è at-least-once — e due
        # esecuzioni entrerebbero entrambe nel loop LLM, cioè due volte il costo. Sotto lock passa
        # uno solo; il secondo trova `running` e se ne va. heartbeat_at nasce qui: da questo momento
        # il record dice che qualcuno lo sta eseguendo DAVVERO, e il silenzio che segue è la prova
        # che quel qualcuno non c'è più.
        return Result.ok(@training) unless claim!

        samples = @dataset.rows.purpose_sample.ordered.includes(cells: { image_attachment: :blob }).to_a
        return fail_run(:not_enough) if samples.size < Datasets::Constants::MIN_SAMPLE_ROWS
        return fail_run(:no_input) if input_columns.empty?
        return fail_run(:no_target) if target_columns.empty?

        fewshot, holdout = split(samples)
        best = optimize(fewshot, holdout)
        return propagate(best) if best.is_a?(Result)

        @training.finish_ok!(system_prompt: best[:prompt], config: best[:config], metrics: best[:metrics])
        @dataset.update!(status: :trained)
        Result.ok(@training)
      rescue StandardError => e
        Rails.logger.error("Datasets::Trainings::Run failed training=#{@training.id}: #{e.class} #{e.message}")
        @training.finish_err!(code: "R500-SYSTEM-001", message: I18n.t("datasets.errors.internal"))
        Result.err(AppError.new(I18n.t("datasets.errors.internal"), code: "R500-SYSTEM-001", status: :internal_server_error))
      end

      private

      # `with_lock` ricarica la riga e la blocca: lo stato letto è quello vero, non la copia in memoria.
      def claim!
        @training.with_lock do
          next false unless @training.status_pending?

          @training.update!(status: :running, heartbeat_at: Time.current)
          true
        end
      end

      def input_columns = @dataset.input_columns

      def target_columns = @dataset.target_columns

      # Partizione DISGIUNTA: righe riservate all'holdout (valutazione) mai usate come few-shot
      # (costruzione), così l'accuratezza misura generalizzazione e non riproduzione del training set.
      # ~1/3 all'holdout (cap HOLDOUT_MAX); con MIN_SAMPLE_ROWS≥3 restano sempre entrambi non vuoti e
      # disgiunti (N=3→2/1, N=8→5/3, N=14→6/5).
      def split(samples)
        holdout_size = [ (samples.size / 3.0).ceil, Datasets::Constants::HOLDOUT_MAX ].min
        holdout = samples.last(holdout_size)
        fewshot = (samples - holdout).first(Datasets::Constants::SAMPLE_FEWSHOT_MAX)
        [ fewshot, holdout ]
      end

      # Loop build→evaluate→refine. Ritorna il miglior candidato {prompt, metrics, config} oppure un
      # Result.err (gateway) da propagare.
      def optimize(fewshot, holdout)
        best = nil
        mistakes = []
        Datasets::Constants::MAX_ITERATIONS.times do |iteration|
          # Un giro è due chiamate lunghe al servizio AI: il battito qui è il segno che l'esecuzione
          # sta ancora avanzando, e tiene il recupero (CYRA-791) lontano da chi è solo lento.
          @training.beat!
          prompt = Datasets::Ai::BuildPrompt.call(dataset: @dataset, examples: fewshot, input_columns:,
                                                  target_columns:, mistakes:, client: @client)
          return prompt if prompt.err?

          metrics = Datasets::Ai::Evaluate.call(system_prompt: prompt.value, rows: holdout, input_columns:,
                                                target_columns:, client: @client)
          return metrics if metrics.err?

          value = metrics.value
          candidate = { prompt: prompt.value, metrics: value,
                        config: { "iteration" => iteration + 1, "fewshot_ids" => fewshot.map(&:id),
                                  "model" => ::Ai::Configuration.current.chat_model } }
          best = candidate if best.nil? || value["overall_accuracy"] > best[:metrics]["overall_accuracy"]
          break if value["overall_accuracy"] >= Datasets::Constants::TARGET_ACCURACY

          mistakes = value["mistakes"]
        end
        best
      end

      def fail_run(key)
        @training.finish_err!(code: "R422-DATASET-004", message: I18n.t("datasets.errors.#{key}"))
        Result.err(AppError.new(I18n.t("datasets.errors.#{key}"), code: "R422-DATASET-004"))
      end

      def propagate(result)
        @training.finish_err!(code: result.error.code, message: result.error.message)
        result
      end
    end
  end
end
