# frozen_string_literal: true

# Ticket per la CLI. `code` = identificatore umano (key progetto + numero). status/priority come label.
# Espone il corpo COMPLETO (description + N scenari BDD + N condizioni DoD + analisi tecnica) e i
# riferimenti umani (assignee/reporter/reviewer per nome, milestone/platforms per label): la CLI è il
# canale d'analisi dei ticket e deve vedere tutto ciò che vede la show web — mai meno.
class TicketSerializer < ApplicationSerializer
  attributes :id, :title, :project_id, :description, :technical_analysis, :weight, :votes_count,
             :due_at, :created_at, :updated_at

  attribute(:code) { |ticket| ticket.code }
  attribute(:kind) { |ticket| ticket.kind }
  # Gate di eleggibilità agenti (CYRA-184): la CLI è il canale di analisi e deve vedere quello che
  # vede la pagina — soprattutto il PERCHÉ di un blocco, che è ciò su cui si decide se ribaltarlo.
  attribute(:agent_eligibility) { |ticket| ticket.agent_eligibility }
  attribute(:agent_eligibility_reason) { |ticket| ticket.agent_eligibility_reason }
  attribute(:agent_eligibility_source) { |ticket| ticket.agent_eligibility_source }
  attribute(:agent_eligibility_decided_at) { |ticket| ticket.agent_eligibility_decided_at }
  attribute(:status) { |ticket| ticket.status&.label }
  attribute(:priority) { |ticket| ticket.priority&.label }
  # Colore del badge (nome famiglia Tailwind, es. amber/emerald/orange) — la CLI lo traduce in pallino
  # di stato (🟡🟢🔴). Serve un token stabile perché le label sono personalizzabili dall'org.
  attribute(:status_color) { |ticket| ticket.status&.color }
  attribute(:priority_color) { |ticket| ticket.priority&.color }
  # Status STABILE (id/code/category) OLTRE alla label già esposta come `status`: le label sono
  # personalizzabili dall'org e localizzate → instabili per l'automazione, che si aggancia a code
  # (stringa) o category (enum del workflow). CYRA-83.
  attribute(:status_ref) { |ticket| StatusReference.for(ticket.status) }
  attribute(:assignee) { |ticket| ticket.assignee&.name }
  attribute(:reporter) { |ticket| ticket.reporter&.name }
  attribute(:reviewer) { |ticket| ticket.reviewer&.name }
  attribute(:milestone) { |ticket| ticket.milestone&.label }
  # Epic padre: id (per rimandarlo a un update) + code, che è l'identità leggibile in output.
  attribute(:parent_id) { |ticket| ticket.parent_id }
  attribute(:parent) { |ticket| ticket.parent&.code }
  attribute(:platforms) { |ticket| ticket.platforms.map(&:label) }

  # Dipendenze (CYRA-83): `blocked` = ha un prerequisito ancora aperto, `workable` il complemento.
  # SNAPSHOT — l'automator ticket-worker ri-verifica il gating autoritativo prima di lavorare, non si
  # fida di questo flag. Anti-N+1: l'index passa params[:blocked_ids] (una query aggregata per l'intera
  # collection, mai un blocked? per riga); dettaglio in StatusReference#blocked?.
  attribute(:blocked) { |ticket| StatusReference.blocked?(ticket, params) }
  attribute(:workable) { |ticket| !StatusReference.blocked?(ticket, params) }

  # Scenari e DoD in ordine (has_many :ordered). Chiavi allineate ai flag CLI.
  attribute(:scenarios) do |ticket|
    ticket.scenarios.map do |scenario|
      { title: scenario.title, step_given: scenario.step_given, step_when: scenario.step_when,
        step_then: scenario.step_then, step_expected: scenario.step_expected }
    end
  end
  attribute(:conditions) { |ticket| ticket.conditions.map { |condition| { text: condition.text } } }

  # Guidance risolta del progetto del ticket (CYRA-74): references + procedures composte org → gruppo →
  # progetto, ciascuna con la sua origine. Presente SOLO nel dettaglio (show), dove il controller la
  # pre-calcola e la passa via params; in index params è vuoto e l'attributo è omesso, così la lista non
  # paga la risoluzione né cambia forma. Mai copiata nel testo del ticket: il consumer legge quella risolta.
  attribute :guidance, if: proc { params[:guidance] } do |_ticket|
    Guidance::ResolutionSerializer.new(params[:guidance]).serializable_hash
  end

  # Answered questions (CYAU-240): every answer is a decision taken on the ticket. Without them the diff
  # review judged a choice settled by an answer as a choice the implementer took alone.
  # Detail (show) only, like guidance: the index pays no query and keeps its shape. The param is the
  # questions the reader may see (Ticketing::Question.readable_by), never all of them.
  attribute :answered_questions, if: proc { params[:answered_questions] } do |ticket|
    ticket.answered_question_decisions(params[:answered_questions])
  end
end
