# frozen_string_literal: true

module Errors
  # Assegna (o disassegna, id vuoto) un gruppo d'errore a una persona (CYRA-153). Gemello di
  # Ticketing::AssignTicket, ma senza timeline: gli errori non hanno un feed di attività, quindi la
  # traccia è lo stato stesso del gruppo.
  #
  # L'assignee dev'essere membro dell'org del progetto (anti-BOLA): un id fuori org non viene trovato
  # e resta non assegnato — stesso comportamento di AssignTicket, per non fidarsi mai di un id arrivato
  # dal client. Il model ribadisce l'invariante con una validazione, così nessun percorso può scrivere
  # un assignee estraneo.
  #
  # NON broadcasta: come Errors::Triage, il realtime vive nel controller Member (canale con view), non
  # qui — questo service è condiviso col canale CLI, che non ha da spingere HTML a nessuno.
  class Assign < ApplicationService
    def initialize(group:, assignee_id:, organization: nil)
      @group = group
      @assignee_id = assignee_id
      @organization = organization || group.project.organization
    end

    def call
      # blank → disassegna. id fuori org → nil (non trovato nello scope dell'org): non assegna a un
      # estraneo, al più lascia il gruppo senza assegnatario.
      assignee = @assignee_id.blank? ? nil : @organization.accounts.find_by(id: @assignee_id)
      # No-op: stesso assignee (incluso nil == nil = già non assegnato) → nessuna scrittura.
      return Result.ok(@group) if assignee&.id == @group.assignee_id

      @group.update!(assignee: assignee)
      Result.ok(@group)
    end
  end
end
