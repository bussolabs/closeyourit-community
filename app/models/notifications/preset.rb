# frozen_string_literal: true

module Notifications
  # Configurazioni pronte della pagina notifiche (CYRA-443): tre scelte che scrivono in un gesto la
  # cadenza di TUTTI gli avvisi del catalogo, per chi arriva davanti a 40+ righe e non sa da dove
  # partire. Registry COSTANTE dev-defined come Notifications::Catalog (eccezione enum-static di
  # rules/lookup-tables.md): non è un dato dell'organizzazione, è il modo in cui il prodotto suggerisce
  # una partenza sensata.
  #
  # VERSIONATA di proposito (rischio dichiarato nel ticket): applicare una configurazione SOSTITUISCE
  # le scelte fatte a mano, quindi la definizione non può derivare in silenzio da un rilascio all'altro.
  # Cambiare le liste = bumpare VERSION e aggiornare il lock nello spec.
  #
  # Scrive SOLO la matrice per-avviso: i canali (email/Telegram acceso o spento) e le ore silenziose
  # restano scelte a mano, perché dicono dove e quando ti si può disturbare — non quali avvisi ti
  # interessano. L'in-app resta sempre consegnata e non compare qui.
  class Preset
    # v2 (CYRA-712): il rientro del servizio generativo (ai_available) entra fra i ritorni alla
    # normalità, che in «Essenziale» restano spenti — l'in-app li mostra comunque.
    # v3 (CYAG-22): cluster_down is critical, cluster_up joins the recoveries.
    VERSION = 3

    IMMEDIATE = Cadence::IMMEDIATE
    DAILY = Cadence::DAILY
    OFF = Cadence::OFF

    # Avvisi che riguardano la persona: qualcuno ti ha assegnato, menzionato o ti sta aspettando.
    # Arrivano subito anche nella configurazione "Essenziale", perché il ritardo costa a un altro.
    PERSONAL_EVENT_TYPES = %w[
      ticket_assigned ticket_mentioned ticket_review_requested ticket_review_rejected ticket_review_approved
      chat_mentioned secret_change_requested
    ].freeze

    # Ritorni alla normalità: il ripristino non è una notizia urgente. Spenti in "Essenziale" —
    # l'in-app li mostra comunque, che è dove si va a guardare se una cosa è rientrata.
    RECOVERY_EVENT_TYPES = %w[
      uptime_up server_up server_container_up server_container_stable server_replication_up
      ai_available cluster_up
    ].freeze

    # Rumore di fondo per chi vuole solo l'essenziale: apertura di ticket e idee altrui, chiacchiere,
    # oscillazioni di traffico. Restano tutti nel centro notifiche.
    BACKGROUND_EVENT_TYPES = %w[
      ticket_created chat_message idea_created idea_commented
      analytics_traffic_drop analytics_traffic_spike
    ].freeze

    # default = cadenza per tutto ciò che non è elencato; le liste per cadenza sovrascrivono il default.
    # Ordine delle chiavi = ordine dei bottoni nella pagina.
    DEFINITIONS = {
      "essential" => {
        default: DAILY,
        immediate: PERSONAL_EVENT_TYPES + Catalog::CRITICAL_EVENT_TYPES + %w[vulnerability_new],
        off: RECOVERY_EVENT_TYPES + BACKGROUND_EVENT_TYPES
      },
      "everything" => { default: IMMEDIATE, immediate: [], off: [] },
      "urgent_only" => { default: OFF, immediate: Catalog::CRITICAL_EVENT_TYPES, off: [] }
    }.freeze

    KEYS = DEFINITIONS.keys.freeze

    def self.all = KEYS.map { |key| new(key) }

    # Configurazione per chiave, o nil se la chiave è fuori vocabolario (il form manda uno dei tre
    # bottoni: qualunque altra cosa è manipolazione e non deve scrivere niente).
    def self.find(key) = KEYS.include?(key.to_s) ? new(key.to_s) : nil

    attr_reader :key

    def initialize(key)
      @key = key
    end

    def label = I18n.t("member.notifications.presets.#{key}.label")
    def hint = I18n.t("member.notifications.presets.#{key}.hint")

    # Matrice completa {event_type => cadenza} su TUTTI gli avvisi del catalogo: una configurazione
    # parziale lascerebbe righe al valore precedente, che è il modo peggiore di "applicare un preset".
    def cadences
      definition = DEFINITIONS.fetch(key)
      immediate = definition[:immediate]
      off = definition[:off]

      Catalog.event_types.index_with do |event_type|
        next IMMEDIATE if immediate.include?(event_type)
        next OFF if off.include?(event_type)

        definition[:default]
      end
    end
  end
end
