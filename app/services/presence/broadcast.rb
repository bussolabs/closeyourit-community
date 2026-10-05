# frozen_string_literal: true

module Presence
  # Emette (via Turbo) la lista avatar degli account online, PER-VIEWER: ogni viewer online riceve
  # sul proprio stream (`Realtime::Streams.presence_for(org, viewer)`) SOLO gli online che può
  # vedere (Presence::Cohort — chi condivide un progetto/gruppo/team, più owner e sé stesso;
  # owner/god vedono tutti). Sostituisce il vecchio broadcast org-wide unico, che mostrava l'intera
  # org a chiunque.
  #
  # Fan-out: si iterano i soli viewer ONLINE (gli unici con una subscription attiva). Costo
  # O(online²) nel caso peggiore ma `online` è l'insieme dei connessi in quel momento (piccolo).
  #
  # Diffing PER-VIEWER: per ciascun viewer si confronta la firma del SUO insieme visibile con
  # l'ultima emessa (fingerprint in Realtime::Presence, ora per-viewer). Così gli heartbeat
  # (frequenti, insieme invariato) non generano traffico, e un join/leave aggiorna solo i viewer
  # il cui insieme visibile è effettivamente cambiato. Il riempimento iniziale della tab entrante
  # (insieme invariato per lei) NON passa di qui: lo copre lo snapshot diretto di PresenceChannel.
  #
  # Tenant: lo stream è org+account-prefissato da Realtime::Streams e la lista è filtrata da
  # Cohort sui membri reali dell'org → nessun leak cross-organizzazione né cross-viewer.
  class Broadcast < ApplicationService
    def initialize(organization:)
      @organization = organization
    end

    def call
      online = Realtime::Presence.online(@organization).to_a
      cohort = Presence::Cohort.new(organization: @organization, online: online)

      online.each { |viewer| broadcast_to(viewer, cohort.visible_for(viewer)) }

      Result.ok(online)
    end

    private

    def broadcast_to(viewer, accounts)
      fingerprint = accounts.map(&:id).sort.join(",")
      return if fingerprint == Realtime::Presence.last_fingerprint(@organization, viewer)

      Realtime::Presence.store_fingerprint(@organization, viewer, fingerprint)
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.presence_for(@organization, viewer),
        target: "presence_list",
        partial: "member/presence/list",
        locals: { accounts: accounts, viewer: viewer }
      )
    end
  end
end
