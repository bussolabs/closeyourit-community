# frozen_string_literal: true

module Guides
  # Da quale pagina si arriva a quale guida (CYRA-437). Le guide sono viste statiche di
  # Member::GuidesController: qui vive l'unico punto che dice, dato il path della pagina che stai
  # guardando, quale guida la spiega. Ui::PageHeaderComponent la interroga e rende il rimando
  # accanto al titolo, così ogni pagina di funzionalità porta alla propria guida senza che
  # chi scrive la vista debba ricordarsene.
  #
  # Le regole si leggono in ordine e la prima che combacia vince: le più specifiche stanno
  # sopra le più generiche (/member/knowledge/reviews prima di /member/knowledge, altrimenti la
  # revisione finirebbe sulla guida della knowledge base).
  #
  # Terzo elemento facoltativo della regola: la SEZIONE della guida a cui atterrare (CYRA-432). Serve
  # dove una schermata non ha una guida propria e crearne una sarebbe crearla vuota: si manda al
  # capitolo che la spiega dentro la guida generale, non in cima a una pagina da leggere tutta.
  #
  # Una guida nuova va aggiunta qui: `spec/models/guides/map_spec.rb` fallisce se una guida
  # esiste ma nessuna pagina la raggiunge.
  class Map
    RULES = [
      [ %r{\A/member/monitoring/measurements\b}, "measurements" ],
      [ %r{\A/member/monitoring/sessions\b}, "session_health" ],
      [ %r{\A/member/monitoring/traces\b}, "traces" ],
      [ %r{\A/member/monitoring/error\b},                                   "errors" ],
      # CYRA-485 — i lavori programmati hanno una guida loro: mandarli a quella dei siti era
      # mandarli nel posto sbagliato.
      [ %r{\A/member/monitoring/cron\b},                                       "crons"  ],
      [ %r{\A/member/monitoring/(monitors|groups|incidents)\b},          "uptime" ],
      [ %r{\A/member/monitoring/performance\b},                           "performance" ],
      [ %r{\A/member/monitoring/logs\b},                             "logs" ],
      # CYRA-376 — le sessioni registrate non avevano una guida: la pagina spiegava quando compaiono,
      # mai come si accendono.
      [ %r{\A/member/monitoring/replays\b},                                 "replays" ],
      [ %r{\A/member/monitoring/(servers|databases|tokens)\b},       "servers" ],
      [ %r{\A/member/monitoring/analytics\b},                               "analytics" ],
      [ %r{\A/member/monitoring/vulnerabilities\b},                         "vulnerabilities" ],
      [ %r{\A/member/monitoring/(seo|sites)\b},                         "seo" ],
      # CYRA-79 — i valori assegnati a una persona sola hanno una guida loro: la pagina del vault
      # spiega i secret del progetto, non l'eccezione per-persona (che è la parte meno intuitiva).
      [ %r{\A/member/projects/[^/]+/secrets/overrides\b},                    "secret_overrides" ],
      # CYRA-777 — la pagina di conferma di un «valore in comune» apre la guida che spiega cosa il
      # prodotto sta guardando e cosa succede accettando.
      [ %r{\A/member/vault/consolidations\b},                                "shared_values" ],
      [ %r{\A/member/(shared|personal)/(secrets|files)\b},        "secrets" ],
      [ %r{\A/member/vault\b},                                              "vault" ],
      [ %r{\A/member/knowledge/reviews\b},                                  "knowledge_review" ],
      # Le raccolte non hanno una guida tutta loro: atterrano sul capitolo che le spiega.
      [ %r{\A/member/knowledge/books\b},                                    "knowledge", "books" ],
      [ %r{\A/member/knowledge\b},                                          "knowledge" ],
      [ %r{\A/member/tickets\b},                                            "tickets" ],
      [ %r{\A/member/helpdesk\b},                                           "helpdesk" ],
      [ %r{\A/member/projects/[^/]+/helpdesk\b},                            "helpdesk" ],
      # CYRA-454 — i Dataset erano l'unica funzione dell'area Automazione senza guida: chi apriva la
      # pagina (vuota da mesi) non aveva dove leggere quando serve e cosa NON è.
      [ %r{\A/member/datasets\b},                                           "datasets" ],
      # CYRA-501 — le macchine che lavorano i ticket e la versione delle competenze che eseguono:
      # dalla pagina non si arrivava a nessuna spiegazione, e non ce n'era una da raggiungere.
      [ %r{\A/member/agents\b},                                             "agents" ],
      [ %r{\A/member/skills\b},                                       "skill_bundles" ],
      [ %r{\A/member/product/matrix\b},                                     "feature_matrix" ],
      [ %r{\A/member/home/approvals\b},                                     "approvals" ],
      [ %r{\A/member/(organization|groups/[^/]+|projects/[^/]+)/guidance\b}, "guidance" ],
      # CYRA-879 — the move pages of a project or group open the guide on moving between organizations.
      [ %r{\A/member/(groups|projects)/[^/]+/move\b},                       "project_moves" ],
      [ %r{\A/member/(roles|teams)\b},                                     "permissions" ],
      # CYRA-745 — dal registro si arriva alla guida che dice cosa ci si trova e cosa no.
      [ %r{\A/member/activity\b},                                          "activity" ],
      # CYRA-545 — i servizi esterni collegati con la chiave dell'organizzazione. La regola copre
      # anche la pagina della GitHub App, che di quell'elenco è una scheda.
      [ %r{\A/member/integrations\b},                                      "integrations" ],
      # CYRA-160 — dalla pagina in cui si sceglie ogni quanto arriva il riepilogo dei dati si va
      # alla guida che dice cosa contiene e perché non è la stessa cosa degli avvisi.
      [ %r{\A/member/preferences/notifications\b},                         "reports" ],
      # CYRA-441 — i contenitori: l'Amministrazione era un elenco nudo di voci, e piattaforme e
      # ambienti aprivano su una tabella senza una parola su cosa fossero. Dopo la regola della
      # guidance, così le istruzioni per gli assistenti restano sulla propria guida.
      [ %r{\A/member/(settings|platforms|environments|organization)\b},     "structure" ]
    ].freeze

    # Guide che NON spiegano una pagina ma il prodotto nel suo insieme (CYRA-435): non hanno un
    # path da cui essere raggiunte, e il posto da cui si aprono è l'indice delle guide. Stanno qui
    # perché la spec di copertura possa continuare a dire «nessuna guida orfana» senza pretendere
    # che ognuna abbia una pagina sorgente.
    # CYRA-782 — «questions» sta qui per un motivo diverso dalle altre due: spiega una SCHEDA della
    # pagina di un ticket, e la scheda vive in un parametro (`?tab=questions`) che `slug_for` non
    # vede — riceve il percorso, non la query. Una regola non potrebbe mai distinguerla da
    # `/member/tickets`, che ha già la sua guida. Si raggiunge dall'indice delle guide e dal link
    # nella voce di changelog.
    STANDALONE = %w[overview ticket_lifecycle questions assistant].freeze

    class << self
      # Slug della guida che spiega la pagina, o nil se quella pagina non ne ha una.
      def slug_for(path)
        rule_for(path)&.at(1)
      end

      # Path della guida della pagina corrente, già risolto sulle rotte (mai costruito a mano:
      # se la rotta cambia, il rimando la segue), con la sezione quando la regola la dichiara.
      def path_for(path)
        rule = rule_for(path)
        return nil if rule.nil?

        guide = Rails.application.routes.url_helpers.public_send(:"member_guides_#{rule[1]}_path")
        rule[2] ? "#{guide}##{rule[2]}" : guide
      end

      def slugs
        RULES.map { |_pattern, slug, _section| slug }.uniq
      end

      private

      def rule_for(path)
        return nil if path.blank?

        without_query = path.split("?").first
        RULES.find { |pattern, _slug, _section| pattern.match?(without_query) }
      end
    end
  end
end
