# frozen_string_literal: true

require "base64"

module Datasets
  module Ai
    # Genera (o raffina) via LLM il system_prompt che, dagli input, fa predire i target. Riceve lo schema
    # (input + target con tipi/opzioni), un campione di righe etichettate (few-shot, con qualche immagine
    # inline) e — nel refine — gli errori dell'iterazione precedente. Output vincolato da uno schema (`response_schema`).
    class BuildPrompt < ApplicationService
      MAX_TOKENS = 1500

      SCHEMA = {
        type: "object",
        properties: { system_prompt: { type: "string", description: I18n.t("datasets.ai.build_prompt_field") } },
        required: %w[system_prompt]
      }.freeze

      # ATTENZIONE, è un META-prompt: il testo che produce viene salvato e riusato da
      # Datasets::Ai::Predict. Ordinare qui di «rispondere tramite la funzione submit_prediction»
      # metterebbe quell'istruzione dentro ogni prompt salvato dagli utenti — verso una funzione che
      # con `response_schema` non esiste più (CYRA-594).
      SYSTEM_PROMPT = <<~PROMPT.freeze
        Sei un ingegnere di prompt. Devi produrre un SYSTEM PROMPT che, dato l'input descritto (testo
        e/o immagini), guidi un LLM a predire gli attributi target. Rispondi con `system_prompt`: un
        prompt chiaro e conciso che (1) spiega come dedurre ciascun target dagli input, (2) elenca i
        valori ammessi per gli attributi categoriali, (3) impone di compilare tutti gli attributi target
        richiesti, senza aggiungerne altri.
        NON includere gli esempi nel prompt: servono solo a te per capire il compito. Usa la lingua degli
        esempi.
      PROMPT

      def initialize(dataset:, examples:, input_columns:, target_columns:, mistakes: [], client: nil)
        @dataset = dataset
        @examples = examples
        @input_columns = input_columns
        @target_columns = target_columns
        @mistakes = mistakes
        @client = client
      end

      def call
        client = @client || build_client

        args = ::Ai::Structured.call(client: client, system: SYSTEM_PROMPT, user: task_text,
                                     images: example_images, schema: SCHEMA, max_output_tokens: MAX_TOKENS)
        prompt = args["system_prompt"].to_s.strip
        return unreadable if prompt.blank?

        Result.ok(prompt)
      rescue ::Ai::Llm::Client::Error => e
        Result.err(AppError.new(e.message, code: e.code, status: e.status))
      rescue KeyError
        # AI_* mancante → errore pulito, mai un 500 (stessa regola di Embeddings::EmbedText).
        Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
      rescue JSON::ParserError, TypeError
        unreadable
      end

      private

      # Chiave e indirizzo del server AI vengono da ENV: nessuna credenziale per organizzazione.
      def build_client = ::Ai::Llm::Client.new

      def task_text
        [ schema_text, examples_text, mistakes_text ].reject(&:blank?).join("\n\n")
      end

      def schema_text
        inputs = @input_columns.map { |column| "- #{column.label} (#{column.kind})" }.join("\n")
        targets = @target_columns.map { |column| "- #{column.code} (#{target_type(column)})" }.join("\n")
        "Input disponibili:\n#{inputs}\n\nAttributi target da predire:\n#{targets}"
      end

      def target_type(column)
        column.kind_category? ? "category: #{column.option_values.join('/')}" : column.kind
      end

      def examples_text
        rows = @examples.first(Datasets::Constants::PROMPT_EXAMPLES_MAX)
        return "" if rows.empty?

        lines = rows.map.with_index(1) { |row, index| "Esempio #{index} → #{example_pairs(row)}" }
        "Esempi etichettati:\n#{lines.join("\n")}"
      end

      # Coppie input-scalari + target attesi (le immagini vanno come parti separate, vedi example_images).
      def example_pairs(row)
        inputs = @input_columns.reject(&:kind_photo?).map { |c| "#{c.label}=#{row.value_for(c.code)}" }
        targets = @target_columns.map { |c| "#{c.code}=#{row.value_for(c.code)}" }
        (inputs + [ "⇒" ] + targets).join(", ")
      end

      def mistakes_text
        return "" if @mistakes.empty?

        lines = @mistakes.first(Datasets::Constants::PROMPT_MISTAKES_MAX).map do |mistake|
          "#{mistake['code']}: atteso #{mistake['expected']}, predetto #{mistake['predicted']}"
        end
        "Errori del prompt precedente da correggere:\n#{lines.join("\n")}"
      end

      # Le foto degli esempi nel dialetto dei chiamanti: mime type e base64 separati, non la data URL in
      # stile OpenAI — quella viene ignorata in silenzio (CYRA-594).
      def example_images
        cells = @examples.lazy.flat_map do |row|
          @input_columns.select(&:kind_photo?).filter_map do |column|
            row.cells.detect { |c| c.column_id == column.id && c.image.attached? }
          end
        end
        cells.first(Datasets::Constants::MAX_INLINE_IMAGES).map do |cell|
          { mime_type: cell.image.content_type, data: Base64.strict_encode64(cell.image.download) }
        end
      end

      def unreadable
        Result.err(AppError.new(I18n.t("datasets.errors.ai_unreadable"), code: "R502-DATASET-002", status: :bad_gateway))
      end
    end
  end
end
