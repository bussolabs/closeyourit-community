# frozen_string_literal: true

# CYRA-742 — le pagine delle prestazioni avevano un file di supporto solo: le categorie, le soglie di
# durata, i due grafici e il dettaglio di un'occorrenza, tutto insieme. Qui resta l'elenco delle
# parti, ognuna con UN compito; il nome resta perché una vista continua a chiamare i metodi per nome.
#
#   Metrics::StatusHelper       categoria, tipo di problema, stato di triage, firma leggibile
#   Metrics::ThresholdsHelper   le soglie che decidono veloce/medio/lento e la frase che le dichiara
#   Metrics::DurationsHelper    quanto è durato: media, variazione, percentili, tempo cumulato
#   Metrics::ChartsHelper       le barre dei grafici occorrenze e durata
#   Metrics::OccurrencesHelper  il dettaglio di una occorrenza letto dal payload del campione
module MetricsHelper
  include Metrics::StatusHelper
  include Metrics::ThresholdsHelper
  include Metrics::DurationsHelper
  include Metrics::ChartsHelper
  include Metrics::OccurrencesHelper
end
