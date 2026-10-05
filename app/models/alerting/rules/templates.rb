# frozen_string_literal: true

module Alerting
  module Rules
    # I modelli pronti per i casi più comuni (CYRA-482). Il caso più frequente — «avvisami se il sito
    # cade» — non aveva nessuna scorciatoia: il form si apriva su un evento di error monitoring, e per
    # arrivarci bisognava riconoscere «Uptime down» fra ventitré voci. Peggio: il ciclo completo vuole
    # DUE regole (caduta e ritorno) e questo non era scritto da nessuna parte, quindi chi ne creava una
    # sola sapeva quando il sito cadeva e non sapeva mai quando era tornato.
    #
    # Registry COSTANTE dev-defined, come Notifications::Catalog: un modello nuovo è codice, non
    # configurazione. Renderli personalizzabili per organizzazione (l'"Aperto" del ticket) sarebbe
    # un'altra cosa — un contenitore con CRUD, permessi e storia — non un'opzione di questa costante.
    #
    # Gli event_type vengono dal catalogo unificato (CYRA-480): un modello che ne citasse uno fuori
    # elenco fa fallire lo spec, quindi non possono divergere al primo rename.
    class Templates
      Template = Struct.new(:key, :event_types, :throttle_minutes, keyword_init: true) do
        def title = I18n.t("member.alerting.rules.templates.#{key}.title")
        def description = I18n.t("member.alerting.rules.templates.#{key}.description")
        def creates_pair? = event_types.size > 1

        # Cosa verrà creato, detto PRIMA della conferma: è la parte che mancava.
        def outcome
          I18n.t("member.alerting.rules.templates.#{key}.outcome",
                 events: event_types.filter_map { |type| ::Notifications::Catalog.entry(type)&.title }.to_sentence)
        end
      end

      ALL = [
        Template.new(key: "site_down", event_types: %w[uptime_down uptime_up], throttle_minutes: 5),
        Template.new(key: "cron_missed", event_types: %w[cron_missed], throttle_minutes: 15),
        Template.new(key: "new_errors", event_types: %w[error_new], throttle_minutes: 10),
        Template.new(key: "server_health", event_types: %w[server_down server_disk], throttle_minutes: 15)
      ].freeze

      def self.all = ALL
      def self.find(key) = ALL.find { |template| template.key == key.to_s }
    end
  end
end
