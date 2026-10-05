# Politica di ritentativo comune a tutti i lavori in background (CYRA-713).
#
# Prima si riprovava OGNI `StandardError` tre volte, quindi anche un `NoMethodError`: un difetto del
# programma che il secondo tentativo ripete identico. Su un fornitore a pagamento quel giro triplica
# il costo di ogni errore, e chi guarda i guasti li vede arrivare con l'attesa crescente di due
# tentativi inutili addosso. Ora si riprova solo ciò che può guarire da sé (`TransientFailure`).
#
# Tutto il resto FALLISCE subito — fallisce, non viene scartato: un difetto va visto. Uno
# `discard_on` su `NoMethodError` e parenti lo lascerebbe nell'elenco dei lavori finiti bene, e
# nessuno saprebbe che non è successo niente.
#
# I job devono restare idempotenti: un ritentativo ripete il lavoro, non lo raddoppia.
class ApplicationJob < ActiveJob::Base
  MAX_ATTEMPTS = 3

  retry_on TransientFailure, wait: :polynomially_longer, attempts: MAX_ATTEMPTS

  # Se il record sottostante non esiste più, scartare invece di ritentare all'infinito.
  discard_on ActiveJob::DeserializationError
end
