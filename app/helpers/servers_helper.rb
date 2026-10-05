# frozen_string_literal: true

# CYRA-742 — le pagine delle macchine avevano un file di supporto solo, seicentocinquanta righe: i
# grafici, gli stati delle unit di sistema, i dischi, i container, i formati dei numeri. Chi doveva
# cambiare il colore di una barra apriva lo stesso file di chi doveva cambiare il testo di uno stato.
#
# Qui non c'è più nessuna regola: c'è l'elenco delle parti, ognuna con UN compito. Il nome resta
# perché è quello con cui le prove e le altre parti citano le costanti (`ServersHelper::PCT_CRIT`) e
# perché una vista continua a chiamare i metodi per nome, come prima.
#
#   Servers::StatusHelper       lo stato di una macchina e la coda dei suoi comandi
#   Servers::MeasuresHelper     che cosa misura una metrica e come si legge il suo valore
#   Servers::ChartsHelper       le barre dei grafici (view-model di Ui::HistogramComponent)
#   Servers::AxesHelper         gli assi Y, una scala per famiglia
#   Servers::FilesystemsHelper  i dischi, i totali e l'unico formato dei byte
#   Servers::SystemdHelper      le unit di sistema e la distinzione fra ferma e rotta
#   Servers::ContainersHelper   i container, le connessioni al database, il registro di sistema
#   Servers::DatabasesHelper    la crescita di un database e la sua variazione
#   Servers::FormatHelper       i testi brevi: gradi, carico, soglie, "tre minuti fa"
module ServersHelper
  include Servers::StatusHelper
  include Servers::MeasuresHelper
  include Servers::ChartsHelper
  include Servers::AxesHelper
  include Servers::FilesystemsHelper
  include Servers::SystemdHelper
  include Servers::ContainersHelper
  include Servers::DatabasesHelper
  include Servers::FormatHelper
end
