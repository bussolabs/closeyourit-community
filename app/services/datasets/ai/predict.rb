# frozen_string_literal: true

require "base64"

module Datasets
  module Ai
    # Applica un system_prompt agli input di UNA riga → valori predetti per ogni colonna target, con
    # risposta vincolata da uno schema e contenuto multimodale (testo + immagini base64). Riusato da
    # Evaluate (holdout) e da Datasets::Predictions::Predict (inferenza).
    class Predict < ApplicationService
      MAX_TOKENS = 1024

      # `organization:` è sparita col CYRA-765: serviva a scegliere la chiave di chi paga la
      # chiamata, e la chiamata la paga il sistema. Questo service gira dentro un ciclo (l'holdout di
      # un training), quindi passarla avrebbe voluto dire ricaricare riga→dataset→progetto a ogni
      # giro per un dato che nessuno legge più.
      def initialize(system_prompt:, row:, input_columns:, target_columns:, client: nil)
        @system_prompt = system_prompt
        @row = row
        @input_columns = input_columns
        @target_columns = target_columns
        @client = client
      end

      def call
        if ::Ai::Feature.disabled?(:dataset_predictions)
          return Result.err(::Ai::Feature.disabled_error(:dataset_predictions))
        end

        client = @client || ::Ai::Llm::Client.new

        args = ::Ai::Structured.call(client: client, system: @system_prompt, user: input_text,
                                     images: image_parts, schema: schema, max_output_tokens: MAX_TOKENS)
        Result.ok(coerce(args))
      rescue ::Ai::Llm::Client::Error => e
        Result.err(AppError.new(e.message, code: e.code, status: e.status))
      rescue KeyError
        # AI_* mancante → errore pulito, mai un 500 (stessa regola di Embeddings::EmbedText).
        Result.err(AppError.new(I18n.t("ai.not_configured"), code: "R502-LLM-002", status: :bad_gateway))
      rescue JSON::ParserError, TypeError
        Result.err(AppError.new(I18n.t("datasets.errors.ai_unreadable"), code: "R502-DATASET-002", status: :bad_gateway))
      end

      private

      def input_text
        lines = @input_columns.reject(&:kind_photo?).map { |column| "#{column.label}: #{@row.value_for(column.code)}" }
        ([ I18n.t("datasets.ai.input_heading") ] + lines).join("\n")
      end

      # Le foto nel dialetto dei chiamanti: mime type e base64 in campi separati. È Ai::Llm::Messages
      # a ricomporle in data URL per il wire OpenAI, e una parte che il client non riconosce sparisce e
      # predice sul solo testo (CYRA-594).
      def image_parts
        cells = @input_columns.select(&:kind_photo?).filter_map do |column|
          cell = @row.cells.detect { |c| c.column_id == column.id && c.image.attached? }
          cell
        end
        cells.first(Datasets::Constants::MAX_INLINE_IMAGES).map do |cell|
          { mime_type: cell.image.content_type, data: Base64.strict_encode64(cell.image.download) }
        end
      end

      # Uno schema con un campo per ogni target (tipo derivato dal kind).
      def schema
        { type: "object", properties: target_properties, required: @target_columns.map(&:code) }
      end

      def target_properties
        @target_columns.to_h { |column| [ column.code, property_for(column) ] }
      end

      def property_for(column)
        case column.kind
        when "category" then { type: "string", enum: column.option_values, description: column.label }
        when "boolean"  then { type: "boolean", description: column.label }
        when "number"   then { type: "number", description: column.label }
        else { type: "string", description: column.label }
        end
      end

      # Valori predetti come stringhe stabili (per confronto/salvataggio), keyed per target code.
      def coerce(args)
        @target_columns.to_h { |column| [ column.code, args[column.code].to_s ] }
      end
    end
  end
end
