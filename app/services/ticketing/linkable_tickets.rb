# frozen_string_literal: true

module Ticketing
  # CYRA-364 — le poche voci che il campo «Ticket collegato» deve mostrare, invece delle duecento
  # dell'intera organizzazione. Alimenta sia il render iniziale del <select> (query vuota → i più
  # aggiornati di recente) sia l'endpoint che lo rifornisce mentre si digita.
  #
  # Il codice del ticket (CYRA-364) NON è una colonna: è `project.key` + `-` + `number`. Cercarlo
  # vuol dire riconoscerne la forma nella query e tradurla in chiave-del-progetto + numero, perché
  # un ILIKE su una colonna che non esiste non troverebbe mai niente.
  #
  # `scope` arriva già ristretto alla visibilità di chi cerca (visible.tickets): qui non si
  # allarga mai, si restringe soltanto — l'anti-BOLA resta dove è sempre stato.
  class LinkableTickets < ApplicationService
    LIMIT = 8

    # "CYRA-364", "cyra 364", "CYRA364", "364": chiave opzionale + numero, nient'altro attorno.
    CODE_QUERY = /\A(?<key>[a-z][a-z0-9_]*)?[\s-]*(?<number>\d+)\z/i

    def initialize(scope:, query: nil, project_ids: nil, all: false, limit: LIMIT)
      @scope = scope
      @query = query.to_s.strip
      @project_ids = project_ids
      @all = all
      @limit = limit
    end

    def call
      relation = narrowed(@scope.preload(:project))
      relation = matching(relation) if @query.present?
      relation.order(updated_at: :desc).limit(@limit)
    end

    private

    # Contesto (i progetti del team scelto): salta quando chi cerca ha chiesto esplicitamente tutta
    # l'organizzazione, e quando il contesto non risolve nessun progetto — restringere a zero
    # progetti darebbe un campo sempre vuoto, che sembra rotto e non lo è.
    def narrowed(relation)
      return relation if @all || @project_ids.blank?

      relation.where(project_id: @project_ids)
    end

    # Titolo sempre; codice solo se la query ne ha la forma. `or` esige due relation con gli stessi
    # preload/join: entrambe nascono da `relation`, quindi differiscono solo nel where.
    def matching(relation)
      by_code = code_relation(relation)
      by_title = relation.where("ticketing_tickets.title ILIKE ?", like(@query))
      by_code ? by_title.or(by_code) : by_title
    end

    def code_relation(relation)
      match = CODE_QUERY.match(@query)
      return nil unless match

      by_number = relation.where(number: match[:number].to_i)
      key = match[:key]
      return by_number if key.blank?

      by_number.where(project_id: Projects::Project.where("key ILIKE ?", like(key, prefix: true)).select(:id))
    end

    def like(text, prefix: false)
      escaped = ActiveRecord::Base.sanitize_sql_like(text)
      prefix ? "#{escaped}%" : "%#{escaped}%"
    end
  end
end
