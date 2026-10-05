# frozen_string_literal: true

require "rails_helper"

# CYRA-25 — Audit: ogni pagina show rende i metadati SOLO come pill meta del componente header
# (Ui::PageHeaderComponent + Ui::StatLabelComponent). Guard statico sul markup delle show elencate:
# niente pill copiate a mano (classe BASE di StatLabel duplicata), niente Ui::BadgeComponent come
# metadato nell'header, e uso effettivo di Ui::StatLabelComponent. Previene anche le regressioni future.
RSpec.describe "Conformità pill meta nelle show (CYRA-25)" do
  # Frammento distintivo della classe BASE di Ui::StatLabelComponent: se compare in una view è una
  # pill copiata a mano (la BASE deve vivere SOLO nel componente).
  HANDROLLED_BASE = "border border-stone-200 bg-white px-2 py-0.5 text-[11.5px]"

  # Tutte le show/partial toccati dall'audit (tickets/show è coperto da CYRA-23; projects/show usa
  # l'header custom _overview_header ma già con StatLabel; knowledge/pages tiene i meta nella sidebar).
  SHOWS = %w[
    app/views/member/monitoring/error_groups/show.html.erb
    app/views/member/monitoring/monitors/show.html.erb
    app/views/member/monitoring/log_entries/show.html.erb
    app/views/member/ideas/show.html.erb
    app/views/member/agents/show.html.erb
    app/views/member/workload/actions/show.html.erb
    app/views/member/knowledge/versions/show.html.erb
    app/views/member/todo_lists/show.html.erb
    app/views/member/todo_lists/sharings/show.html.erb
    app/views/member/changelog/show.html.erb
    app/views/member/monitoring/servers/_labels.html.erb
  ].freeze

  # Shows whose metadata moved to a Details panel on the right, like the ticket page (page refactor
  # 2026-10-01): the header carries no pills, so only the "no hand-rolled pill / no badge" rules apply.
  DETAILS_PANEL_SHOWS = %w[
    app/views/member/ideas/show.html.erb
    app/views/member/workload/actions/show.html.erb
    app/views/member/monitoring/servers/_labels.html.erb
  ].freeze

  # Show il cui header non deve contenere alcun Ui::BadgeComponent (i metadati sono SOLO StatLabel).
  # monitors/show è escluso: ha badge legittimi nel titolo (env) e nel pannello config del body.
  # CYRA-828: i contatori aggiornati via Turbo vivono in un partial dentro l'header.
  META_PARTIALS = {
    "app/views/member/todo_lists/show.html.erb" => "app/views/member/todo_lists/_stats.html.erb"
  }.freeze
  NO_BADGE = (SHOWS - %w[app/views/member/monitoring/monitors/show.html.erb] + META_PARTIALS.values).freeze

  def source(path) = File.read(Rails.root.join(path))

  # CYRA-748 — da quando le show grandi sono spezzate in partial, l'header non vive più nel file
  # della show: viene reso da un `_header.html.erb` accanto. Il guard deve seguirlo, altrimenti
  # smette di guardare proprio la parte che gli interessa e passa per assenza. Se la view non
  # dichiara l'header e ne rende uno, il file da esaminare è quel partial.
  def header_path(path)
    return path if source(path).include?("Ui::PageHeaderComponent")

    reso = source(path)[/render\s+"([\w\/]*header)"/, 1]
    return path if reso.nil?

    partial = reso.include?("/") ? reso.sub(%r{([^/]+)\z}, '_\\1') : "#{File.dirname(path).sub("#{Rails.root}/", "")}/_#{reso}"
    candidate = partial.start_with?("app/views") ? partial : "app/views/#{partial}"
    candidate += ".html.erb" unless candidate.end_with?(".html.erb")
    File.exist?(Rails.root.join(candidate)) ? candidate : path
  end

  # Il markup che il guard deve esaminare: la view più, quando c'è, il partial del suo header.
  def markup(path)
    header = header_path(path)
    content = header == path ? source(path) : source(path) + source(header)
    content += source(META_PARTIALS.fetch(path)) if META_PARTIALS.key?(path)
    content
  end

  # Delimitatori dei blocchi ERB, per isolare l'header dal resto della view.
  ERB_BLOCK_OPEN = /\bdo\s*(?:\|[^|]*\|)?\s*-?%>|<%-?=?\s*(?:if|unless|case)\b/
  ERB_BLOCK_END = /<%-?\s*end\s*-?%>/

  # Il divieto di Ui::BadgeComponent vale per l'HEADER, non per l'intera pagina: sotto l'header una
  # view può avere badge legittimi (la barra del ticket in error_groups/show è uno di questi, e con
  # un guard esteso a tutto il file bloccava il rilascio). Ritaglia dal render del PageHeaderComponent
  # fino al tag che chiude il suo blocco. Una view senza header non ha un header da proteggere:
  # resta sotto esame per intero, così il guard non si allenta dove serviva davvero.
  def header_source(path)
    path = header_path(path)
    lines = source(path).lines
    start = lines.index { |line| line.include?("Ui::PageHeaderComponent") }
    return source(path) if start.nil?


    depth = 0
    opened = false
    lines[start..].each_with_index do |line, offset|
      depth += line.scan(ERB_BLOCK_OPEN).size
      depth -= line.scan(ERB_BLOCK_END).size
      opened ||= depth.positive?
      return lines[start..(start + offset)].join if opened && depth <= 0
    end
    lines[start..].join
  end

  SHOWS.each do |path|
    describe path do
      it "non contiene pill copiate a mano (classe BASE di StatLabel)" do
        expect(markup(path)).not_to include(HANDROLLED_BASE)
      end

      unless DETAILS_PANEL_SHOWS.include?(path)
        it "rende i metadati con Ui::StatLabelComponent" do
          expect(markup(path)).to include("Ui::StatLabelComponent")
        end
      end
    end
  end

  NO_BADGE.each do |path|
    it "#{path} non usa Ui::BadgeComponent come metadato dell'header" do
      expect(header_source(path)).not_to include("Ui::BadgeComponent")
    end
  end

  # Guard sul guard: se il ritaglio dell'header smettesse di funzionare e restituisse tutto il file,
  # il divieto sopra tornerebbe a bocciare badge legittimi del body; se ritagliasse troppo poco, non
  # proteggerebbe più niente. Su una show lunga l'header deve essere una porzione, e contenere i meta.
  describe "il ritaglio dell'header" do
    # Header inline insieme al resto della pagina: il ritaglio deve essere una PORZIONE.
    it "su una show con header inline prende l'header e non il resto della pagina" do
      path = "app/views/member/monitoring/monitors/show.html.erb"
      header = header_source(path)

      expect(header.lines.size).to be < source(path).lines.size
      expect(header).to include("Ui::PageHeaderComponent", "Ui::StatLabelComponent")
    end

    # CYRA-748 — dove l'header è stato estratto in un partial suo, il ritaglio coincide con quel
    # file: è il comportamento giusto, non un guard che ha smesso di ritagliare. Quello che qui va
    # provato è che il guard SEGUA la delega, invece di guardare una show che l'header non ce l'ha
    # più e passare per assenza.
    it "su una show che delega l'header a un partial guarda quel partial" do
      path = "app/views/member/monitoring/error_groups/show.html.erb"

      expect(header_path(path)).to eq("app/views/member/monitoring/error_groups/_header.html.erb")
      expect(header_source(path)).to include("Ui::PageHeaderComponent", "Ui::StatLabelComponent")
    end
  end

  # Le label delle StatLabel introdotte dalla migrazione devono esistere in entrambe le lingue.
  # `raise_on_missing_translations` è off in test → senza questo guard un typo/indentazione errata
  # passerebbe come "translation missing" a runtime senza rompere gli spec.
  NEW_LABEL_KEYS = %w[
    member.monitoring.logs.show.level
    member.monitoring.logs.show.occurred
    member.ideas.show.status_label
    member.ideas.show.project_label
    member.ideas.show.author_label
    member.agents.show.status_label
    member.agents.show.slots_label
    member.agents.show.running_label
    member.agents.show.certification_label
    member.agents.show.heartbeat_label
    member.workload.actions.team_label
    member.workload.actions.status_label
    member.workload.actions.scheduled_label
    member.todo_lists.progress_label
    member.todo_lists.shared_by_label
    member.todo_lists.share.list_label
    member.knowledge.versions.status_label
    member.knowledge.versions.kind_label
    member.knowledge.versions.author_label
    member.knowledge.versions.created_label
    member.servers.show.status_label
    member.servers.show.hostname_label
    member.servers.show.os_label
    member.servers.show.agent_label
    shared.changelog.latest_label
  ].freeze

  %i[it en].each do |locale|
    NEW_LABEL_KEYS.each do |key|
      it "la chiave i18n #{key} esiste in #{locale}" do
        expect(I18n.exists?(key, locale)).to be(true)
      end
    end
  end
end
