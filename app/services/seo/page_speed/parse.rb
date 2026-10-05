# frozen_string_literal: true

module Seo
  module PageSpeed
    # Dalla risposta di PageSpeed Insights agli attributi di un `Seo::LabRun` (CYRA-539). Puro:
    # niente rete, niente database. Tollera tutto — una risposta a cui manca un pezzo produce una
    # misura in meno, mai un'eccezione: il giro è già costato mezzo minuto a Google, e buttarlo via
    # perché una chiave non c'era sarebbe uno spreco oltre che un guasto.
    #
    # Tre trappole di questa API, tutte già costate a qualcuno:
    #
    # 1. `categories.*.score` è un DOUBLE in 0..1 e PUÒ ESSERE NULL. Va reso come percentuale e
    #    `null` deve restare `nil`: `nil.to_i == 0` dipingerebbe di rosso un sito che nessuno ha
    #    misurato. È la coercizione più pericolosa dell'intera integrazione.
    # 2. Il CLS di campo arriva moltiplicato per cento (`percentile` è int32, il CLS è decimale).
    # 3. Il discovery document dice che `percentile` per la v5 contiene «pc90». È OBSOLETO: la
    #    pagina «About PageSpeed Insights» dice che PSI riporta il 75° percentile per tutte le
    #    metriche, su una finestra di 28 giorni. Non ricascarci.
    class Parse
      def self.call(...) = new(...).call

      def initialize(response)
        @response = response.is_a?(Hash) ? response : {}
      end

      def call
        attrs = { final_url: @response["id"].presence, lighthouse_version: lighthouse["lighthouseVersion"].presence }
        attrs.merge!(scores).merge!(lab_metrics).merge!(field)
      end

      private

      def lighthouse = @response["lighthouseResult"].is_a?(Hash) ? @response["lighthouseResult"] : {}

      def scores
        categories = lighthouse["categories"]
        return {} unless categories.is_a?(Hash)

        Constants::SCORE_COLUMNS.filter_map do |key, column|
          score = categories.dig(key, "score")
          # `nil` non è zero: qui si esce senza scrivere la colonna, che resta NULL.
          next if score.nil?

          [ column, (score.to_f * Constants::SCORE_SCALE).round ]
        end.to_h
      end

      def lab_metrics
        audits = lighthouse["audits"]
        return {} unless audits.is_a?(Hash)

        values = Constants::LAB_AUDITS.filter_map do |name, column|
          numeric = audits.dig(name, "numericValue")
          next if numeric.nil?

          [ column, numeric.round ]
        end.to_h

        cls = audits.dig("cumulative-layout-shift", "numericValue")
        values[:lab_cls] = cls.to_f.round(4) unless cls.nil?
        values
      end

      # I dati dei visitatori veri che Google ha già. `loadingExperience` riguarda QUESTA URL;
      # quando non ne ha abbastanza risponde con l'origine intera e lo dichiara con
      # `origin_fallback`. Dire «questa pagina» quando il dato è di tutto il sito è una bugia, e la
      # colonna esiste per non raccontarla.
      def field
        experience = @response["loadingExperience"]
        experience = @response["originLoadingExperience"] unless experience.is_a?(Hash) && experience["metrics"].present?
        return {} unless experience.is_a?(Hash)

        metrics = experience["metrics"].is_a?(Hash) ? experience["metrics"] : {}
        attrs = {
          field_origin_fallback: !!experience["origin_fallback"],
          field_overall_category: experience["overall_category"].presence,
          field_distributions: distributions(metrics)
        }

        Constants::FIELD_METRICS.each do |key, column|
          percentile = metrics.dig(key, "percentile")
          attrs[column] = percentile.round unless percentile.nil?
        end

        cls = metrics.dig(Constants::CLS_FIELD_KEY, "percentile")
        attrs[:field_cls] = (cls / Constants::CLS_SCALE).round(4) unless cls.nil?
        attrs
      end

      # Le tre fasce per metrica, così come le manda Google: sono la prova sotto il p75, e servono a
      # far vedere QUANTI utenti stanno in ciascuna invece di un numero solo.
      def distributions(metrics)
        metrics.filter_map do |key, value|
          distributions = value.is_a?(Hash) ? value["distributions"] : nil
          next unless distributions.is_a?(Array)

          [ key, distributions ]
        end.to_h
      end
    end
  end
end
