# frozen_string_literal: true

# Helper di presentazione per la sezione Agents host-first (CYAU-88). Colori Tailwind LITERAL (mai
# interpolati) coerenti col precedente Servers: online=emerald, offline=gray, busy=indigo,
# waiting=amber, recovery_required=red.
#
# CYRA-742 — trecento righe in un file solo: lo stato di una macchina, i formati delle durate, i
# riquadri del rendimento e i pallini della timeline. Qui resta l'elenco delle parti, ognuna con UN
# compito; il nome resta perché una vista continua a chiamare i metodi per nome.
#
#   Agents::StatusHelper       in che stato è una macchina e cosa sta facendo adesso
#   Agents::DurationsHelper    i formati: durata, costo, percentuale
#   Agents::TrendsHelper       la variazione rispetto al periodo precedente
#   Agents::PerformanceHelper  i riquadri del rendimento, quali mostrare e cosa scrivono
#   Agents::CompareHelper      il confronto fra macchine, una riga per misura
#   Agents::TimelineHelper     il percorso di una lavorazione: pallini, etichette, segmenti
module AgentsHelper
  include Agents::StatusHelper
  include Agents::DurationsHelper
  include Agents::TrendsHelper
  include Agents::PerformanceHelper
  include Agents::CompareHelper
  include Agents::TimelineHelper
end
