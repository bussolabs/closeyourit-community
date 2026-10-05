# frozen_string_literal: true

module Ui
  # Breadcrumb del design system: trail "Home / Area / … / corrente" reso in cima all'header
  # di pagina (regola: back → breadcrumb obbligatoria rooted sulla Home). Il crumb root
  # è SEMPRE anteposto come prima voce; l'ultimo crumb è la pagina corrente
  # (testo, senza link, aria-current="page"); i crumb intermedi con href sono link.
  #
  # `crumbs` = array di { label:, href: } (href opzionale). Il root è configurabile per area:
  # member → root_path (default), valhalla → valhalla_root_path via root_href/root_label.
  # Strutturale: le label arrivano dai chiamanti (i18n a call-site).
  class BreadcrumbComponent < BaseComponent
    def initialize(crumbs:, root_href: nil, root_label: nil, test_id: "breadcrumb", **options)
      @crumbs = Array(crumbs)
      @root_href = root_href
      @root_label = root_label
      @test_id = test_id
      @options = options
    end

    private

    # Radice sempre in testa, poi l'AREA in cui ci si trova (CYRA-335: era l'unico posto che dice
    # «dove sono» e saltava proprio quel livello), poi i crumb del chiamante.
    def all_crumbs
      [ { label: root_label, href: root_href } ] + group_crumb + @crumbs
    end

    # L'area viene dalla stessa sorgente che accende la sidebar, così le due non possono divergere.
    # Niente crumb per una voce fissa (Home, Approvazioni, Conversazioni, Attività, Guide: stanno già
    # al primo livello), per un gruppo senza panoramica, o quando il chiamante ha già messo l'area come
    # primo livello — è il caso della panoramica del gruppo stesso.
    def group_crumb
      return [] unless helpers.respond_to?(:current_group)

      group = helpers.current_group
      return [] if group.nil? || group.pinned?
      return [] if @crumbs.first&.dig(:label) == group.label

      href = helpers.group_overview_path(group)
      [ { label: group.label, href: href } ]
    end

    def root_href
      @root_href || helpers.root_path
    end

    # La radice si chiama come la voce di menu che porta allo stesso posto: due nomi per la stessa
    # pagina («Dashboard» qui, «Home» nel menu) lasciavano credere che fossero due posti diversi.
    def root_label
      @root_label || I18n.t("member.nav.home")
    end

    def last_index
      all_crumbs.size - 1
    end

    # Un crumb è link solo se non è l'ultimo (la corrente è sempre testo) e ha un href.
    def link_crumb?(crumb, index)
      index != last_index && crumb[:href].present?
    end

    def nav_attributes
      merge_options(base_class: "flex items-center", test_id: @test_id, options: @options)
        .merge("aria-label": "breadcrumb")
    end
  end
end
