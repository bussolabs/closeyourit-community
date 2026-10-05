# frozen_string_literal: true

# Presa in carico di un ticket da parte di un account, condivisa fra il canale web (Member) e quello
# della CLI: entrambi parlano con gli stessi Agents::Leases::*, e senza questo confine comune le due
# copie divergerebbero proprio sul punto delicato — l'identità della lavorazione.
module TicketLeaseOperations
  extend ActiveSupport::Concern

  private

  # Ogni presa nasce con un run id NUOVO. Un id stabile (per account o per token) sembra più semplice
  # e non lo è: il rilascio scrive un tombstone su (ticket, titolare, run_id), e Acquire rifiuta per
  # sempre un run già rilasciato (R409-LEASE-002). Con un id stabile, il primo rilascio renderebbe
  # quel ticket non più prendibile da quella persona — mai più, e senza un modo di accorgersene se
  # non provando. Vale anche per gli agenti: la skill autopilot mette il timestamp nel proprio.
  def new_lease_run_id(prefix) = "#{prefix}:#{SecureRandom.uuid}"

  # Per rinnovare o rilasciare non si indovina il run id: si legge quello del lease che il titolare
  # detiene davvero. Così il ticket preso dalla riga di comando si rilascia dalla pagina e viceversa,
  # e nessun client deve conservare stato locale per ritrovare la propria lavorazione.
  # nil quando il titolare non ha nulla su quel ticket: le operazioni rispondono 404, che è corretto.
  #
  # `active_only` serve alla presa: riusare il run di un lease ATTIVO la rende idempotente (ripremere
  # "Prendi in carico" non è un conflitto con sé stessi), mentre riusare quello di un lease SCADUTO
  # sarebbe un autogol — Acquire lo leggerebbe come "questo run è finito" e risponderebbe
  # R409-LEASE-002 invece di lasciar riprendere il proprio ticket.
  def held_lease_run_id(ticket, account, active_only: false)
    lease = ::Agents::Lease.find_by(ticket:, account:)
    return if lease.nil?
    return if active_only && !lease.active_at?(::Agents::Leases::Clock.current)

    lease.run_id
  end
end
