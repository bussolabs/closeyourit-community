# frozen_string_literal: true

# Helper di serializzazione dello stato del ticket, condivisi tra TicketSerializer e
# TicketDependencySerializer nel canale CLI (CYRA-83). Nessuna logica di dominio: solo forma stabile.
module StatusReference
  module_function

  # Status STABILE per l'automazione: id + code (stringa) + category (enum del workflow) OLTRE alla
  # label, che l'org personalizza ed è localizzata → non è un contratto su cui agganciarsi. nil-safe:
  # un ticket senza status → nil.
  def for(status)
    return nil if status.nil?

    { id: status.id, code: status.code, category: status.category, label: status.label }
  end

  # "Bloccato" (SNAPSHOT): l'index CLI precalcola params[:blocked_ids] con UNA query aggregata per
  # l'intera collection (mai un blocked? per riga → niente N+1). Fuori dall'index (singolo record) il
  # Set è assente e si cade su Ticket#blocked?, memoizzato sull'istanza così `blocked` e `workable`
  # dello stesso ticket condividono UNA sola query (Prosopite scatta già a due query identiche).
  def blocked?(ticket, params)
    ids = params && params[:blocked_ids]
    return ids.include?(ticket.id) if ids
    return ticket.instance_variable_get(:@cli_blocked) if ticket.instance_variable_defined?(:@cli_blocked)

    ticket.instance_variable_set(:@cli_blocked, ticket.blocked?)
  end

  # Il blocker di una dipendenza è visibile all'account? Anti-BOLA in LETTURA (parità col web, CYRA-82):
  # un blocker cross-project (ammesso intra-org) può stare in un progetto che chi guarda A non vede →
  # blocker_id/code/title non devono trapelare (leak intra-org). Il controller precalcola
  # params[:visible_blocker_ids] con UNA pluck. Assente → true (es. create, dove il blocker è appena
  # stato validato tra i visibili dal service).
  def blocker_visible?(dependency, params)
    ids = params && params[:visible_blocker_ids]
    return true if ids.nil?

    ids.include?(dependency.blocker_id)
  end
end
