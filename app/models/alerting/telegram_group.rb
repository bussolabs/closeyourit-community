# frozen_string_literal: true

module Alerting
  # Il gruppo Telegram con argomenti dove l'owner riceve i suoi avvisi, uno per organizzazione (CYRA-852).
  # Gli argomenti nascono al primo avviso che li riguarda; `topics` tiene chiave → message_thread_id.
  class TelegramGroup < ApplicationRecord
    self.table_name = "alerting_telegram_groups"

    CRITICAL_TOPIC = "critical"
    OTHER_TOPIC = "other"

    # L'icona di ogni argomento (CYRA-865). Solo le emoji che Telegram ammette per gli argomenti
    # (getForumTopicIconStickers), indicate per id: un'emoji fuori elenco fa rifiutare la creazione.
    TOPIC_ICONS = {
      CRITICAL_TOPIC => "5312241539987020022", # 🔥
      "tickets" => "5373251851074415873", # 📝
      "chat" => "5417915203100613993", # 💬
      "errors" => "5312424913615723286", # 🦠
      "logs" => "5434144690511290129", # 📰
      "performance" => "5350305691942788490", # 📈
      "uptime" => "5312016608254762256", # ⚡️
      "crons" => "5433614043006903194", # 📆
      "servers" => "5350554349074391003", # 💻
      "secrets" => "5418115271267197333", # 🪪
      "tokens" => "5377624166436445368", # 🎟
      "agents" => "5309832892262654231", # 🤖
      "vulnerabilities" => "5377494501373780436", # 👮‍♂️
      "analytics" => "5350713563512052787", # 📉
      "seo" => "5309965701241379366", # 🔎
      "ideas" => "5312536423851630001", # 💡
      "workload" => "5237699328843200968", # ✅
      "datasets" => "5411138633765757782", # 🧪
      "services" => "5237889595894414384", # 🧠
      OTHER_TOPIC => "5377316857231450742" # ❓
    }.freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :account, class_name: "Accounts::Account"

    validates :chat_id, presence: true
    validates :organization_id, uniqueness: true

    # Il gruppo dove va l'avviso di questo destinatario: c'è solo per l'owner attuale che l'ha collegato.
    def self.for_recipient(account:, organization:)
      return if account.nil? || organization.nil?

      group = find_by(organization_id: organization.id, account_id: account.id)
      group if group && organization.owner_membership&.account_id == account.id
    end

    # Gli eventi critici stanno insieme in un argomento solo; gli altri nel loro gruppo del catalogo.
    def self.topic_key(event_type)
      return CRITICAL_TOPIC if Notifications::Catalog.critical?(event_type)

      Notifications::Catalog.group_for(event_type)&.to_s || OTHER_TOPIC
    end

    def self.topic_icon(key) = TOPIC_ICONS.fetch(key, TOPIC_ICONS[OTHER_TOPIC])

    def self.topic_name(key)
      case key
      when CRITICAL_TOPIC, OTHER_TOPIC then I18n.t("telegram.group.topics.#{key}")
      else I18n.t("member.notifications.groups.#{key}")
      end
    end
  end
end
