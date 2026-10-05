# frozen_string_literal: true

module Ticketing
  # CYRA-739 — il suggerimento duplicati del modulo ticket: il perimetro della ricerca, le due
  # soglie, il draft in memoria su cui si misura, la riga che il pannello disegna. Viveva sparso fra
  # sei metodi privati del controller della pagina, insieme a bacheca, ricerca e opzioni del form.
  #
  # Il pannello (mentre si scrive) e la pagina di confronto (al salvataggio) devono misurare LO
  # STESSO testo contro LO STESSO archivio: cambia solo la soglia fra chi PROPONE e chi FERMA.
  # Altrimenti mostrano due percentuali diverse per la stessa coppia e la seconda smentisce la prima
  # («mi diceva 91% e non mi ha fermato»).
  class DedupPresenter
    include ActionView::Helpers::NumberHelper
    include Rails.application.routes.url_helpers

    # Gli id spuntati, con un tetto: tanti quanti il pannello (e la pagina di confronto) ne possono
    # mostrare. Non è una difesa — i bersagli restano comunque solo ticket visibili dello stesso
    # progetto, e collegarli è un gesto che chiunque apra un ticket può fare — ma senza un limite
    # una richiesta scritta a mano con cinquecento id farebbe cinquecento collegamenti e mille righe
    # di cronologia in una transazione sola, dentro il salvataggio di un ticket.
    LINK_TARGETS_LIMIT = Ticketing::FindSimilarTickets::TOP_K

    def self.submitted_link_ids(raw)
      Array(raw).reject(&:blank?).uniq.first(LINK_TARGETS_LIMIT)
    end

    # `attributes` sono i campi del form (non un testo già impastato dal JS), `scope` i ticket che
    # l'account può vedere.
    def initialize(attributes:, scope:)
      @attributes = attributes
      @scope = scope
    end

    # Candidati da PROPORRE nel pannello del form: soglia larga. nil quando non c'è niente da
    # cercare (draft senza titolo o senza progetto), che è uno stato normale del form.
    def panel_matches = matches(min_similarity: Constants::DUPLICATE_PANEL_SIMILARITY)

    # Candidati che FERMANO la creazione con la pagina di confronto: stessa ricerca, soglia stretta.
    # Servizio embedding giù → [] (il create procede: degrado silenzioso, come ovunque tocchiamo l'AI).
    def gate_matches
      result = matches(min_similarity: Constants::DUPLICATE_GATE_SIMILARITY)
      return [] if result.nil? || result.err?

      result.value
    end

    # Draft in memoria dai campi del form (MAI salvato): serve per il testo semantico e per la
    # colonna destra del confronto. kind difensivo come CreateTicket (enum invalido solleverebbe).
    def draft
      @draft ||= begin
        attributes = @attributes.to_h.symbolize_keys
        attributes[:kind] = attributes[:kind].presence || :bug
        attributes[:platform_ids] = Array(attributes[:platform_ids]).reject(&:blank?)
        Ticketing::Ticket.new(attributes)
      end
    end

    # I simili spuntati nel pannello, risolti in ticket veri. Ristretti al progetto del draft e a ciò
    # che l'account può vedere: un id arrivato a mano da fuori semplicemente non esiste. Nessun
    # filtro di stato, invece — lo stato decide cosa PROPORRE, non cosa si può collegare, e un ticket
    # chiuso nei secondi fra la spunta e il salvataggio non va rifiutato.
    #
    # `includes(:project)`: la cronologia legge l'organizzazione passando dal progetto, e senza
    # preload sarebbe una query per bersaglio dentro il ciclo.
    def link_targets(ids)
      return [] if ids.empty? || @attributes[:project_id].blank?

      @scope.where(project_id: @attributes[:project_id]).includes(:project).where(id: ids).to_a
    end

    # Payload minimale per il pannello "ticket simili" (niente description: il pannello è compatto).
    # La percentuale arriva già scritta: il JS non traduce e non formatta nulla, e così la stessa
    # cifra si legge uguale qui e nella pagina di confronto.
    def payload(match)
      ticket = match.ticket
      { id: ticket.id, code: ticket.code, title: ticket.title, kind: ticket.kind,
        status_label: ticket.status&.label, url: member_ticket_path(ticket),
        similarity: match.similarity,
        similarity_label: number_to_percentage(match.similarity, precision: 0) }
    end

    private

    # Il perimetro, scritto UNA volta: stesso progetto del draft, ticket visibili all'account, lavoro
    # vivo o chiuso dentro la finestra.
    #
    # nil (non un Result) quando non c'è niente da cercare: i due chiamanti lo rendono ciascuno a
    # modo suo — il pannello con una lista vuota, il gate lasciando passare la creazione.
    def matches(min_similarity:)
      return nil if @attributes[:title].blank? || @attributes[:project_id].blank?

      scope = @scope.where(project_id: @attributes[:project_id]).open_or_recently_closed
      Ticketing::FindSimilarTickets.call(scope: scope, min_similarity: min_similarity,
                                         text: Ticketing::EmbeddingText.call(ticket: draft))
    end
  end
end
