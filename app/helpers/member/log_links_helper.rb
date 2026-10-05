# frozen_string_literal: true

module Member
  # I candidati da collegare a una voce di log (CYRA-346), e come si leggono. La tendina unica dava
  # ~50 ticket identificati dal solo codice e ~22 errori troncati a quaranta caratteri, dove due voci
  # diverse risultavano identiche: nessuno ricorda a memoria quale codice sia quale lavoro.
  module LogLinksHelper
    CANDIDATES = 50
    # Finestra attorno al messaggio: ciò che è successo nelle stesse ore è quasi sempre la ragione per
    # cui lo si sta collegando. Fuori dalla finestra i candidati restano, solo più in basso.
    NEAR_WINDOW = 6.hours

    # Errori dello stesso progetto, i più vicini nel tempo a questo messaggio per primi.
    def link_candidate_errors(entry)
      near, far = entry.project.error_groups.recent.limit(CANDIDATES).to_a.partition do |group|
        group.last_seen_at.present? && (group.last_seen_at - entry.occurred_at).abs <= NEAR_WINDOW
      end
      near.sort_by { |group| (group.last_seen_at - entry.occurred_at).abs } + far
    end

    def link_candidate_tickets(entry)
      near, far = entry.project.tickets.order(created_at: :desc).limit(CANDIDATES).to_a.partition do |ticket|
        (ticket.created_at - entry.occurred_at).abs <= NEAR_WINDOW
      end
      near.sort_by { |ticket| (ticket.created_at - entry.occurred_at).abs } + far
    end

    # Il titolo INTERO: troncarlo a quaranta caratteri è ciò che rendeva due errori diversi
    # indistinguibili. Ci pensa il dropdown a mandare a capo o a troncare a video.
    def link_error_label(group) = group.title.to_s

    def link_ticket_label(ticket) = "#{ticket.code} · #{ticket.title}"

    # Alias usati dalla view (nomi espliciti sul contesto "log").
    alias log_link_error_label link_error_label
    alias log_link_ticket_label link_ticket_label
  end
end
