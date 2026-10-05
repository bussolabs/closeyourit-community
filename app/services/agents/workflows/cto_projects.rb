# frozen_string_literal: true

module Agents
  module Workflows
    # I progetti di cui un account è CTO EFFETTIVO, fra quelli che già vede. È la regola di
    # Projects::Project#effective_cto (`cto || organization.cto`) scritta come query invece che come
    # domanda su un oggetto solo: serve a chi deve filtrare centinaia di lavorazioni in SQL, non a
    # chi ne sta autorizzando una.
    #
    # CYRA-665 — viveva in linea dentro Home::Approvals::Queue, e le lavorazioni in volo se la
    # riscrivevano a modo loro: la coda mostrava i piani dei soli progetti di cui rispondo e la riga
    # in cima alla home contava quelli di chiunque. Due letture della stessa frase, due numeri
    # diversi sulla stessa pagina.
    #
    # Il fallback sull'organizzazione vale SOLO per il suo CTO e SOLO sui progetti senza un CTO
    # proprio: un progetto affidato a qualcun altro è di quel qualcun altro, anche per lui.
    #
    # Il gate d'AZIONE resta Agents::Workflows::CtoGate: quello dice se posso decidere su UNA
    # lavorazione (e controlla anche visibilità e membership), questo compone un perimetro.
    module CtoProjects
      # I progetti visibili di cui sono CTO effettivo. Relation, mai un array: chi la riceve ci
      # innesta una subquery (`select(:id)`) senza materializzare niente.
      def self.scope(account:, organization:, visible_projects:)
        return ::Projects::Project.none if account.nil? || organization.nil?

        if organization.cto_id == account.id
          visible_projects.where("projects.cto_id = :me OR projects.cto_id IS NULL", me: account.id)
        else
          visible_projects.where(projects: { cto_id: account.id })
        end
      end

      # Rispondo di almeno un progetto? È la domanda che decide se un pezzo di interfaccia esiste,
      # quindi `exists?` e non `.any?` su una relation caricata: costa una query che si ferma alla
      # prima riga, e la si fa a ogni caricamento della home.
      def self.any?(account:, organization:, visible_projects:)
        scope(account:, organization:, visible_projects:).exists?
      end
    end
  end
end
