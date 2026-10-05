# frozen_string_literal: true

module Connections
  # Dipendenza direzionale ticket↔ticket (CYRA-80): `ticket` (A) DIPENDE da `blocker` (B), cioè B è
  # prerequisito di A. A è "bloccato" finché B non è in uno status done. Clone del pattern
  # Connections::TicketLink, ma a differenza dei link (metadato simmetrico) la direzione qui è
  # SEMANTICA: il grafo dei blocker deve restare aciclico (A→B→A vietato). Ammessa cross-project
  # intra-org (un ticket backend può bloccare un ticket app), mai cross-organizzazione.
  class TicketDependency < ApplicationRecord
    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :dependencies
    belongs_to :blocker,
               class_name: "Ticketing::Ticket",
               inverse_of: :blocking
    # Attribuzione, non logica: la FK è nullify, quindi può sparire (account cancellato) senza che la
    # dipendenza cambi. Perciò optional — un created_by azzerato resta un record valido.
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    # La TOPOLOGIA della dipendenza è IMMUTABILE dopo la create: una dipendenza è un fatto atomico
    # (come Connections::TicketLink), non si "re-indirizza" — cambiare blocker significa un'altra
    # dipendenza, quindi si elimina e si ricrea. attr_readonly blinda l'invariante su cui poggia
    # l'anti-ciclo: se ticket_id/blocker_id non cambiano mai in update, un ciclo può nascere SOLO da
    # una create (protetta dal lock qui sotto) e il DFS non incontra mai una vecchia riga da escludere.
    attr_readonly :ticket_id, :blocker_id

    validates :blocker_id, uniqueness: { scope: :ticket_id }
    # CYRA-596 — un prerequisito lo mette una PERSONA. Solo alla create, e per due ragioni diverse
    # che si sommano.
    #
    # Le macchine entrano nel sistema con un'utenza di servizio che ha `tickets.edit` sul progetto:
    # le serve per spostare lo stato del ticket a fine lavoro, e con lo stesso permesso potrebbe
    # aggiungere un prerequisito che nessuno ha voluto o togliere quello deciso da una persona. Se
    # succedesse non se ne accorgerebbe nessuno: sparisce una riga, il ticket riparte da solo, e in
    # cronologia resta il nome di un programma accanto a una decisione che era di una persona. Nel
    # disegno nuovo quei legami sono l'unica cosa che tiene in piedi l'ordine deciso da chi approva
    # il piano: se li può riscrivere la macchina che deve obbedirgli, quell'ordine e' un suggerimento.
    #
    # `on: :create` e non sempre: `created_by` e' una FK `nullify`, quindi un account cancellato la
    # azzera. Un legame gia' esistente il cui autore e' sparito deve restare valido, leggibile e
    # rimovibile — una validazione su ogni salvataggio lo renderebbe impossibile da toccare.
    validate :created_by_is_human, on: :create
    validate :not_self_dependency
    validate :same_organization
    validate :no_cycle

    # Difesa concorrenza: la validazione applicativa da sola NON basta contro create concorrenti (due
    # transazioni possono validare "nessun ciclo" e salvare A→B e B→A insieme). Prendiamo un lock
    # deterministico sui ticket coinvolti (id ordinati → no deadlock) e ri-valutiamo il ciclo DENTRO
    # la transazione: la seconda create vede la prima e fallisce. Vive in before_create perché il lock
    # ha senso solo mentre si sta per inserire una riga nuova.
    before_create :reject_cycle_under_lock

    # CYRA-623 — «prerequisito non soddisfatto» in un posto solo. La domanda cambia col momento —
    # per cominciare a lavorare basta che il codice sia unito, per rilasciare in produzione il
    # prerequisito dev'essere vivo là — ma il criterio è uno, e chi lo chiede non lo riscrive.
    #
    # Lo usano il cancello (`Ticketing::DependencyGuard` via `Ticket#unmet_dependencies`), il badge
    # «bloccato» di bacheca ed elenchi, e la coda da cui la macchina prende il lavoro. Erano tre copie
    # della stessa condizione: il giorno che una cambia, le altre restano indietro e la coda serve
    # ticket che il cancello rifiuta — cioè giri di macchina pagati per niente.
    def self.unmet(mode: :released)
      open_scope = joins(blocker: :status)
                 .where.not(types_ticket_statuses: { category: Types::TicketStatus.categories[:done] })
      return open_scope if mode.to_sym == :released

      # `:merged` — il fatto che soddisfa è `closer_staging_verified_at`, scritto dal verificatore
      # dopo aver VISTO la proposta unita (CYRA-620). Mai `closer_staging_completed_at`, che è la
      # dichiarazione della macchina.
      open_scope.where.not(blocker_id: Agents::Workflow.where.not(closer_staging_verified_at: nil).select(:ticket_id))
    end

    # Il prerequisito non soddisfatto correlato alla riga della query esterna: serve alla coda, che
    # deve escludere in SQL — un giro in Ruby ticket per ticket costerebbe una query a riga.
    #
    # Il criterio NON viene riscritto: entra come insieme di blocker (`blocker_id IN (unmet)`). Serve
    # a tenerlo un livello più in dentro, perché `unmet` porta con sé un join su `ticketing_tickets`
    # per leggere lo stato del PREREQUISITO: allo stesso livello quel nome coprirebbe il ticket della
    # query esterna, la correlazione confronterebbe il prerequisito con se stesso e il filtro non
    # escluderebbe niente — verde, silenzioso e inutile. L'insieme interno non dipende da chi dipende
    # da chi, quindi il database lo valuta una volta sola.
    # La colonna esterna è SCRITTA QUI, non ricevuta: interpolare un nome di colonna in una
    # condizione SQL è la forma esatta che un lettore automatico segnala come iniezione, e avrebbe
    # ragione a segnalarla — oggi arriva da una costante, domani da un parametro.
    def self.unmet_for_outer(mode: :released)
      where("connections_ticket_dependencies.ticket_id = ticketing_tickets.id")
        .where(blocker_id: unmet(mode:).select(:blocker_id))
    end

    # Id (tra quelli passati) con almeno un prerequisito NON ancora done — i "bloccati". UNA query
    # aggregata, pensata per valutare un'INTERA collection senza un blocked? per riga (niente N+1).
    # Fonte unica per il badge board del web e il serializer del ticket sulla CLI (CYRA-80/82/83).
    def self.blocked_ids_among(ticket_ids)
      ids = Array(ticket_ids).compact
      return Set.new if ids.empty?

      Set.new(unmet.where(ticket_id: ids).distinct.pluck(:ticket_id))
    end

    private

    def created_by_is_human
      return errors.add(:created_by, :blank) if created_by.blank?

      errors.add(:created_by, :must_be_human) unless created_by.human?
    end

    def not_self_dependency
      errors.add(:blocker, :not_self_dependency) if ticket_id.present? && ticket_id == blocker_id
    end

    # Integrità tenant: mai una dipendenza cross-organizzazione (come TicketLink/TicketVote). Il
    # cross-project intra-org è invece ammesso — non si guarda il progetto, solo l'organizzazione.
    def same_organization
      return if ticket.blank? || blocker.blank?

      ticket_org = ticket.project&.organization_id
      blocker_org = blocker.project&.organization_id
      return if ticket_org.blank? || blocker_org.blank?

      errors.add(:blocker, :same_organization) if ticket_org != blocker_org
    end

    # Anti-ciclo (feedback immediato, non concorrente): creando A→B, il ciclo esiste se da B, seguendo
    # i BLOCKER, si torna ad A. Orientamento ESPLICITO: si naviga blocker→dependencies, MAI l'inversa.
    def no_cycle
      return if ticket_id.blank? || blocker_id.blank? || ticket_id == blocker_id

      errors.add(:base, :creates_cycle) if cycle_would_form?
    end

    # Ri-valutazione sotto lock: il vincitore della corsa prende il lock, non trova ciclo, inserisce e
    # committa; il perdente prende il lock DOPO, vede la riga appena inserita e fallisce con :creates_cycle.
    def reject_cycle_under_lock
      lock_involved_tickets
      return unless cycle_would_form?

      errors.add(:base, :creates_cycle)
      throw :abort
    end

    # SELECT ... FOR UPDATE sui due ticket, id ordinati: due transazioni che coinvolgono la stessa
    # coppia lockano nello stesso ordine (niente deadlock) e si serializzano (pattern Projects::Save).
    def lock_involved_tickets
      Ticketing::Ticket.where(id: [ ticket_id, blocker_id ]).order(:id).lock.load
    end

    # DFS iterativo con Set di id visitati: da `blocker_id`, seguendo i blocker (dependency dove il
    # nodo è `ticket`), si raggiunge `ticket_id`? Se sì, la nuova A→B chiuderebbe un ciclo.
    def cycle_would_form?
      target = ticket_id
      visited = Set.new
      stack = [ blocker_id ]

      until stack.empty?
        current = stack.pop
        return true if current == target
        next unless visited.add?(current)

        stack.concat(self.class.where(ticket_id: current).pluck(:blocker_id))
      end

      false
    end
  end
end
