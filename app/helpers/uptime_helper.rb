# frozen_string_literal: true

# CYRA-742 — le pagine dei controlli di raggiungibilità avevano un file di supporto solo: gli stati,
# lo snippet da incorporare, la copertura della finestra e le durate. Qui resta l'elenco delle parti,
# ognuna con UN compito; il nome resta perché una vista continua a chiamare i metodi per nome.
#
#   Uptime::StatusHelper   se un sito è su o giù, la percentuale, il blocco, la fase di un guasto
#   Uptime::EmbedHelper    il codice da copiare per mostrare la status page altrove
#   Uptime::WindowsHelper  la finestra osservata: copertura, tratti vuoti, durata del guasto
module UptimeHelper
  include Uptime::StatusHelper
  include Uptime::EmbedHelper
  include Uptime::WindowsHelper
end
