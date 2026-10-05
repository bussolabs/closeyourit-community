# frozen_string_literal: true

# CYRA-742 — le pagine di errori, metriche e registri avevano un file di supporto solo: la palette
# dei livelli, gli istogrammi, i valori oscurati dagli scrubber e i titoli dei registri, tutto
# insieme. Qui resta l'elenco delle parti, ognuna con UN compito.
#
# Il nome resta perché è quello con cui le prove citano le costanti
# (`MonitoringHelper::LOG_HEADLINE_MAX`) e perché una vista continua a chiamare i metodi per nome.
#
#   Monitoring::ErrorsHelper     livelli, stati e riepilogo di una pagina di occorrenze
#   Monitoring::ChartsHelper     gli istogrammi condivisi: assi, finestre, view-model di una barra
#   Monitoring::ScrubbingHelper  i valori oscurati, distinti dai valori assenti
#   Monitoring::LogsHelper       i registri: titolo di una riga, conteggi, grafico del volume
module MonitoringHelper
  include Monitoring::ErrorsHelper
  include Monitoring::ChartsHelper
  include Monitoring::ScrubbingHelper
  include Monitoring::LogsHelper
end
