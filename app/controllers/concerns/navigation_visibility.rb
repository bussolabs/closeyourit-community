# frozen_string_literal: true

# CYRA-740 — il menu di una pagina è un oggetto solo, costruito quando serve: Navigation::Visibility.
# Qui resta il filo che lo lega al controller.
#
# I predicati mantengono la grafia di prima perché è quella che la barra laterale, le scorciatoie da
# tastiera e le poche pagine che si gatano da sole scrivono per nome: cambiarla vorrebbe dire
# riscrivere ogni voce di menu per un refactor che non cambia niente di quello che si vede.
module NavigationVisibility
  extend ActiveSupport::Concern

  NAV_PREDICATES = %i[
    customer_actor?
    agents_nav_visible? alert_notifications_nav_visible? analytics_nav_visible?
    crons_nav_visible? datasets_nav_visible? errors_nav_visible? helpdesk_nav_visible? logs_nav_visible?
    traces_nav_visible? measurements_nav_visible? performance_nav_visible? product_matrix_nav_visible? replays_nav_visible? session_health_nav_visible?
    seo_nav_visible? servers_nav_visible? session_replay_nav_visible?
    uptime_groups_nav_visible? uptime_nav_visible? vault_change_requests_nav_visible?
    vault_nav_visible? vault_variable_search_nav_visible? vulnerabilities_nav_visible?
    workload_nav_visible?
  ].freeze

  included do
    helper_method(*NAV_PREDICATES)
    # `private: true`: in un controller un metodo pubblico è un'azione, e venti predicati di menu non
    # sono venti pagine.
    delegate(*NAV_PREDICATES, to: :navigation_visibility, private: true)
  end

  private

  # Uno per richiesta: le condizioni del menu si valutano una volta, non a ogni voce disegnata.
  #
  # CYRA-799 — i due collaboratori arrivano espliciti: gli elenchi visibili (`visible`) e i permessi,
  # questi ultimi dalla facciata PUBBLICA del controller — la stessa che usano le viste — perché di
  # là sono metodi privati di proposito e prenderli in prestito con `send` era la delega che il menu
  # non fa più.
  def navigation_visibility
    @navigation_visibility ||= Navigation::Visibility.new(visible: visible, permissions: helpers)
  end
end
