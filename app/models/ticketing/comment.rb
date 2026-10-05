module Ticketing
  # Commento su un ticket. L'autore deve essere membro dell'organizzazione del progetto
  # del ticket (isolamento tenant). Allegati via concern Attachable.
  class Comment < ApplicationRecord
    include Attachable
    include LengthBudget

    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :comments
    belongs_to :author,
               class_name: "Accounts::Account",
               inverse_of: :authored_comments

    # `service` = riga scritta dall'app, non da una persona: "Resoconto aggiornato alla versione 2",
    # "Aggiunta una domanda di chiarimento". Rimpiazza il marker HTML nascosto nel corpo (CYRA-220):
    # col tetto di 240 caratteri in arrivo un commento non può permettersi di spenderne 48 in un
    # commento HTML, e una colonna non si rompe riformattando il testo.
    enum :kind, { human: 0, service: 1 }, prefix: true

    # Ortografia italiana prima del salvataggio (vedi Text::ItalianOrthography): i commenti degli
    # agenti sono la fetta più grande della discussione di un ticket lavorato in automatico.
    normalizes :body,
               with: ->(value) { Text::ItalianOrthography.correct(LengthBudget.normalize_newlines(value)).strip }

    validates :body, presence: true
    # Un commento è un messaggio breve: il testo lungo ha un posto suo (Ticketing::Report). La
    # salvaguardia legacy di LengthBudget qui NON è raggiungibile — un commento non si aggiorna da
    # nessuna parte (rotte `only: %i[index create destroy]` sia web sia CLI, nessun service riscrive
    # body) — ma va tenuta lo stesso: è ciò che rende rilasciabile il tetto SEPARATAMENTE dalla
    # compattazione dei commenti storici. Con la salvaguardia, deployare il tetto sopra righe fuori
    # soglia non può rompere niente; senza, tetto e migrazione dovrebbero uscire insieme e senza
    # finestra di rollback. Costo di tenerla: zero.
    length_budget :body, maximum: Ticketing::Constants::COMMENT_MAX_CHARS
    validate :author_belongs_to_organization

    # Il marker resta letto per le righe scritte prima che `kind` esistesse: sono ~590 in produzione e
    # nessuna migrazione le riclassifica (il default della colonna le rende tutte `human`).
    def automation_generated?
      kind_service? || body.match?(%r{<!--\s*closeyourit-automation:}i)
    end

    # Segnale di RENDERING (CYRA-385): il commento va mostrato come opera di un'automazione (badge
    # dedicato, non l'avatar di una persona). Vero se è una riga di servizio/marcata OPPURE se l'autore
    # è un service account — l'identità operativa reale di un agente (`claude`, `codex`) o di un host
    # (`server-minion-1`). Distinto da automation_generated?, che governa il gate di CANCELLAZIONE: un
    # commento libero scritto da un agente resta cancellabile dal suo autore, ma va comunque etichettato.
    def automated?
      automation_generated? || author&.service?
    end

    # Il testo com'era scritto, prima che la compattazione lo riducesse al riassunto (CYRA-222).
    # Serve a chiunque debba leggere il CONTENUTO e non ciò che si vede in discussione — l'archivio
    # dell'analisi tecnica, per esempio. È ciò che rende indifferente l'ordine fra le passate: che il
    # riassunto sia già passato o no, qui esce sempre lo stesso testo.
    def full_body = original_body.presence || body

    private

    # Isolamento tenant (anti-BOLA): l'autore deve essere membro dell'organizzazione del
    # progetto del ticket. Specchio di Ticketing::Ticket#member_of?.
    def author_belongs_to_organization
      org_id = ticket&.project&.organization_id
      return if org_id.blank? || author.blank?
      return if Connections::Membership.exists?(account_id: author.id, organization_id: org_id)

      errors.add(:author, :not_member)
    end
  end
end
