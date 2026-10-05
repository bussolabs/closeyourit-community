# frozen_string_literal: true

# Beacon di presenza: NON streama HTML (gli aggiornamenti DOM steady-state passano da Turbo,
# stream per-viewer `Realtime::Streams.presence_for`, via Presence::Broadcast). Serve solo a far
# scattare i callback subscribe/unsubscribe → registrazione/rimozione dell'appearance nello store
# (Realtime::Presence), e a riempire la tab entrante con uno snapshot immediato (già filtrato).
#
# Identità/tenant arrivano dalla connection (current_account/current_organization già
# identified_by + risolti anti-BOLA): il client NON passa alcun org id → nessuna escalation.
#
# Multi-tab: ogni tab apre una sua subscription → `add` per tab, `remove` per tab; l'account
# resta online finché ne resta almeno una. L'heartbeat rinfresca il TTL e fa pulizia dei ghost.
class PresenceChannel < ApplicationCable::Channel
  def subscribed
    return reject unless current_organization && connection.live_account

    Realtime::Presence.add(current_organization, current_account)
    # Snapshot SOLO a questa tab: la riempie subito con l'elenco corrente. Indispensabile quando
    # il set online non cambia (es. seconda tab dello stesso utente) → Presence::Broadcast non
    # emette, ma la nuova tab deve comunque vedere chi è già online. Risolve anche la race in cui
    # il broadcast Turbo del subscribe precede la conferma della sottoscrizione turbo_stream_from.
    transmit_snapshot
    Presence::Broadcast.call(organization: current_organization)
  end

  def unsubscribed
    return unless current_organization

    Realtime::Presence.remove(current_organization, current_account)
    Presence::Broadcast.call(organization: current_organization)
  end

  # Heartbeat dal client (entro il TTL dello store): tiene vivo l'account e, propagando il
  # diffing di Presence::Broadcast, rimuove dagli altri eventuali ghost scaduti nel frattempo.
  def heartbeat(_data = {})
    return unless current_organization && connection.live_account

    Realtime::Presence.touch(current_organization, current_account)
    Presence::Broadcast.call(organization: current_organization)
  end

  private

  # Renderizza un <turbo-stream> "replace #presence_list" con l'insieme visibile a QUESTO account
  # (filtrato da Presence::Cohort, come i broadcast) e lo invia SOLO a questa subscription
  # (transmit, non broadcast). Il client lo applica con Turbo.renderStreamMessage → stesso renderer
  # dei broadcast, nessuna injection manuale lato JS.
  def transmit_snapshot
    visible = Presence::Cohort.visible_online(current_organization, current_account)
    # Graffe esplicite: senza, Ruby 4.0 interpreta l'hash a chiavi-stringa come keyword args
    # (transmit ha `via:`) → 0 positional → ArgumentError. Le graffe lo forzano a Hash posizionale.
    transmit({
      "type" => "snapshot",
      "stream" => ApplicationController.render(
        partial: "member/presence/snapshot",
        formats: [ :turbo_stream ],
        locals: { accounts: visible, viewer: current_account }
      )
    })
  end
end
