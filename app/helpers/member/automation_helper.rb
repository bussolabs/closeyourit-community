# frozen_string_literal: true

module Member
  # Presentazione della tab Automazione (CYRA-219). Legge `result` e `review` degli Agents::Attempt —
  # jsonb validati alla consegna contro il contratto agent-result/v1 — e li riduce a ciò che serve
  # leggere: com'è andata, cosa ha concluso la macchina, cosa ha risposto chi l'ha revisionata.
  #
  # Difensivo per costruzione: un attempt interrotto ha `result` vuoto, e uno bocciato può averlo
  # parziale (la delivery scrive comunque il payload arrivato). Nessun accesso qui può alzare — una
  # pagina che esplode mentre la lavorazione gira è esattamente il guasto chiuso da CYRA-217.
  #
  # CYRA-742 — trecento righe in un file solo. Qui resta l'elenco delle parti, ognuna con UN compito;
  # il nome resta perché una vista continua a chiamare i metodi per nome.
  #
  #   Member::AutomationOutcomesHelper        com'è andato un passo e come si chiama ciò che si legge
  #   Member::AutomationStepsHelper           i passi come righe: quali si raccolgono, quanto sono durati
  #   Member::AutomationConsiderationsHelper  cosa ha concluso la macchina, reso per fase
  #   Member::AutomationWorkflowHelper        a che punto è la lavorazione nel suo insieme
  module AutomationHelper
    include AutomationOutcomesHelper
    include AutomationStepsHelper
    include AutomationConsiderationsHelper
    include AutomationWorkflowHelper
  end
end
