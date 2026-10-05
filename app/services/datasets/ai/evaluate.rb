# frozen_string_literal: true

module Datasets
  module Ai
    # Valuta un system_prompt su un holdout di righe etichettate: esegue Predict su ogni riga, confronta
    # i valori predetti con le etichette PER-target, ritorna accuratezza overall + per-target + gli
    # errori (che il loop di training rialimenta nel refine). Se una Predict fallisce, propaga l'errore.
    class Evaluate < ApplicationService
      def initialize(system_prompt:, rows:, input_columns:, target_columns:, client: nil)
        @system_prompt = system_prompt
        @rows = rows
        @input_columns = input_columns
        @target_columns = target_columns
        @client = client
      end

      def call
        per_row = []
        @rows.each do |row|
          result = Datasets::Ai::Predict.call(system_prompt: @system_prompt, row: row,
                                              input_columns: @input_columns, target_columns: @target_columns,
                                              client: @client)
          return result if result.err?

          per_row << { row: row, expected: expected(row), predicted: result.value }
        end
        Result.ok(aggregate(per_row))
      end

      private

      def expected(row)
        @target_columns.to_h { |column| [ column.code, row.value_for(column.code).to_s ] }
      end

      def aggregate(per_row)
        total = 0
        correct = 0
        per_target = Hash.new { |hash, key| hash[key] = { total: 0, correct: 0 } }
        mistakes = []

        per_row.each do |entry|
          @target_columns.each do |column|
            code = column.code
            total += 1
            per_target[code][:total] += 1
            if normalize(entry[:expected][code], column) == normalize(entry[:predicted][code], column)
              correct += 1
              per_target[code][:correct] += 1
            else
              mistakes << { "row_id" => entry[:row].id, "code" => code,
                            "expected" => entry[:expected][code], "predicted" => entry[:predicted][code] }
            end
          end
        end

        {
          "overall_accuracy" => ratio(correct, total),
          "per_target" => per_target.transform_values { |value| ratio(value[:correct], value[:total]) },
          "evaluated" => per_row.size,
          "mistakes" => mistakes
        }
      end

      def ratio(correct, total)
        total.zero? ? 0.0 : (correct.to_f / total).round(3)
      end

      # Confronto tollerante: trim + downcase; i boolean normalizzati a "true"/"false".
      def normalize(value, column)
        normalized = value.to_s.strip.downcase
        return %w[true 1 yes si sì].include?(normalized) ? "true" : "false" if column.kind_boolean?

        normalized
      end
    end
  end
end
