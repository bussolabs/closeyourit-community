# frozen_string_literal: true

# Preview ricca di una risorsa taggata in un messaggio di chat (la feature distintiva): icona + tipo +
# etichetta + stato, linkata alla risorsa. Polimorfico sui 6 tipi taggabili. Reso come chip compatto
# coerente col design system (bordi 1px, mono, accento indigo). Riusa Ui::BadgeComponent per lo stato.
class ChatReferenceCardComponent < Ui::BaseComponent
  # Metadati per tipo: icona FA, chiave i18n del tipo, come derivare label/stato/href.
  # visible: false → il viewer ha PERSO l'accesso alla risorsa (revoca live, es. rimosso dal progetto
  # di un ticket taggato in un vecchio DM): niente label/stato/link, solo placeholder neutro — la
  # revoca RBAC si propaga anche ai riferimenti già postati.
  def initialize(referable:, visible: true, test_id: "chat-reference-card")
    @referable = referable
    @visible = visible
    @test_id = test_id
  end

  def render?
    @referable.present?
  end

  def visible?
    @visible
  end

  def type_key
    case @referable
    when Projects::Project then "project"
    when Ticketing::Ticket then "ticket"
    when Errors::Group then "error"
    when Metrics::Group then "metric"
    when Logs::Entry then "log"
    when Uptime::Monitor then "uptime"
    end
  end

  def icon
    { "project" => "folder", "ticket" => "ticket", "error" => "bug",
      "metric" => "gauge", "log" => "align-left", "uptime" => "heart-pulse" }.fetch(type_key, "link")
  end

  # Etichetta primaria compatta: codice per i ticket, key per i progetti, titolo/nome per il resto.
  def label
    @referable.try(:code) || @referable.try(:key) || @referable.try(:title) || @referable.try(:name) ||
      @referable.id
  end

  # Badge di stato (opzionale) + colore, coerente con le viste di dominio. Solo dove lo stato è una
  # label umana (errori: enum; ticket: status lookup); per le altre risorse nessun badge.
  def status_badge
    case @referable
    when Errors::Group then [ @referable.status, error_color(@referable.status) ]
    when Ticketing::Ticket then [ @referable.status&.label, :indigo ]
    end
  end

  def href
    routes = Rails.application.routes.url_helpers
    case @referable
    when Projects::Project then routes.member_project_path(@referable)
    when Ticketing::Ticket then routes.member_ticket_path(@referable)
    when Errors::Group then routes.member_monitoring_error_group_path(@referable)
    when Metrics::Group then routes.member_monitoring_metric_group_path(@referable)
    when Logs::Entry then routes.member_monitoring_log_entry_path(@referable)
    when Uptime::Monitor then routes.member_monitoring_monitor_path(@referable)
    end
  end

  private

  def error_color(status)
    { "resolved" => :emerald, "ignored" => :gray }.fetch(status.to_s, :red)
  end
end
