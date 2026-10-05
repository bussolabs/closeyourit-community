# frozen_string_literal: true

module Analytics
  # Una misura di velocità presa dal browser di un visitatore vero (CYRA-538).
  #
  # Vive nel dominio Analytics e non in Seo:: per una ragione precisa: il tracker non sa cosa sia un
  # sito SEO, e non deve saperlo. La sua identità sul filo è (chiave pubblica, progetto, ambiente).
  # Attribuire una misura a un sito SEO al momento dell'ingest richiederebbe una lettura sul percorso
  # caldo, e farebbe sparire IN SILENZIO le misure di ogni progetto che un sito SEO non l'ha
  # dichiarato. La scheda di un sito ritrova le sue misure con una join di LETTURA, che è un'altra
  # cosa: progetto + ambiente + host.
  class WebVital < ApplicationRecord
    self.table_name = "analytics_web_vitals"

    belongs_to :project, class_name: "Projects::Project"

    validates :metric, presence: true, inclusion: { in: Seo::Vitals::METRICS }
    validates :value, presence: true
    validates :hostname, :path, :occurred_at, presence: true

    scope :since, ->(instant) { where(occurred_at: instant..) }
    scope :for_metric, ->(metric) { where(metric:) }

    # Il 75° percentile per metrica e per tipo di dispositivo, in UNA query. Si calcola qui e non al
    # rollup perché un p75 NON SI MEDIA: la media dei percentili orari non è il percentile del
    # giorno, e un rollup «ovvio» darebbe numeri sbagliati con l'aria di essere giusti. Quando
    # servirà, servirà una struttura che compone davvero (istogrammi a fasce fisse, t-digest).
    #
    # → { ["lcp", "mobile"] => { p75: 2431.0, samples: 812 }, … }
    def self.percentiles(scope, percentile: Seo::Vitals::PERCENTILE)
      fraction = Float(percentile).fdiv(100)
      expression = sanitize_sql_array(
        [ "percentile_cont(?) WITHIN GROUP (ORDER BY value)", fraction ]
      )

      scope.group(:metric, :device_type)
           .pluck(:metric, :device_type, Arel.sql(expression), Arel.sql("COUNT(*)"))
           .to_h { |metric, device, p75, samples| [ [ metric, device ], { p75:, samples: } ] }
    end
  end
end
