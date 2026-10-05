# frozen_string_literal: true

require "rails_helper"

# CYRA-362 — la pagina di un gruppo mostrava soltanto l'elenco dei nomi dei progetti: per sapere come
# stesse l'insieme bisognava aprirli uno per uno. Ora riassume i progetti che contiene — errori
# aperti, ticket non chiusi, disponibilità delle ultime 24 ore e ultimo rilascio — dichiarando a
# quale periodo si riferisce ogni numero (il rischio segnalato dal ticket: un altro numero ambiguo).
RSpec.describe "Member group roll-up (CYRA-362)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:group) { create(:group, organization: org, name: "CloseYourIt") }
  let(:rails_app) { create(:project, organization: org, group: group, name: "closeyourit-rails") }
  let(:flutter_app) { create(:project, organization: org, group: group, name: "closeyourit-flutter") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def rollup_card(test_id)
    Capybara.string(response.body).find("[data-test='group-rollup-#{test_id}']")
  end

  describe "errori aperti dell'insieme" do
    it "somma gli errori non risolti di tutti i progetti del gruppo" do
      allow_n_plus_one do
        create_list(:error_group, 2, project: rails_app)
        create(:error_group, project: flutter_app)
        create(:error_group, :resolved, project: rails_app)
      end

      get member_group_path(group)

      expect(rollup_card("errors").text).to match(/\b3\b/)
    end

    it "non conta gli errori dei progetti fuori dal gruppo" do
      fuori = create(:project, organization: org)
      create(:error_group, project: fuori)
      rails_app

      get member_group_path(group)

      expect(rollup_card("errors").text).to match(/\b0\b/)
    end

    it "porta all'elenco degli errori filtrato sui progetti del gruppo" do
      rails_app
      flutter_app

      get member_group_path(group)

      link = Capybara.string(response.body).find("a[data-test='group-rollup-errors']")
      expect(link[:href]).to eq(
        member_monitoring_error_groups_path(project_id: [ flutter_app.id, rails_app.id ])
      )
    end
  end

  describe "ticket non chiusi dell'insieme" do
    def install_statuses
      {
        todo: create(:ticket_status, organization: org, code: "open", label: "Open", category: :open, position: 0),
        in_review: create(:ticket_status, organization: org, code: "in_review", label: "In Review", category: :in_progress, position: 1),
        closed: create(:ticket_status, organization: org, code: "closed", label: "Closed", category: :done, position: 2)
      }
    end

    it "somma da fare e in corso dei progetti del gruppo, mai i conclusi" do
      s = install_statuses
      allow_n_plus_one do
        2.times { create(:ticket, project: rails_app, organization: org, status: s[:todo]) }
        create(:ticket, project: flutter_app, organization: org, status: s[:in_review])
        create(:ticket, project: rails_app, organization: org, status: s[:closed])
      end

      get member_group_path(group)

      card = rollup_card("tickets")
      expect(card).to have_text(I18n.t("member.projects.health.tickets_unresolved"))
      expect(card.text).to match(/\b3\b/)
      expect(card).to have_text(I18n.t("member.projects.health.tickets_total", n: 4))
    end

    it "porta alla lista dei ticket filtrata sugli status non conclusi dei progetti del gruppo" do
      s = install_statuses
      rails_app
      flutter_app

      get member_group_path(group)

      link = Capybara.string(response.body).find("a[data-test='group-rollup-tickets']")
      expect(link[:href]).to eq(
        list_member_tickets_path(project_id: [ flutter_app.id, rails_app.id ],
                                 status_id: [ s[:todo].id, s[:in_review].id ])
      )
    end
  end

  describe "disponibilità dell'insieme" do
    it "media la percentuale delle ultime 24 ore dei monitor del gruppo e dichiara il periodo" do
      sempre_su = create(:uptime_monitor, project: rails_app)
      meta_giu = create(:uptime_monitor, project: flutter_app)
      allow_n_plus_one do
        2.times { create(:uptime_check, monitor: sempre_su, checked_at: 1.hour.ago) }
        create(:uptime_check, monitor: meta_giu, checked_at: 1.hour.ago)
        create(:uptime_check, :down, monitor: meta_giu, checked_at: 2.hours.ago)
      end

      get member_group_path(group)

      card = rollup_card("uptime")
      expect(card).to have_text("75%") # (100 + 50) / 2
      expect(card).to have_text(I18n.t("member.projects.health.uptime_24h"))
    end

    it "senza controlli recenti non inventa una percentuale" do
      create(:uptime_monitor, project: rails_app)

      get member_group_path(group)

      expect(rollup_card("uptime")).to have_text("—")
    end
  end

  describe "ultimo rilascio dell'insieme" do
    it "mostra la release più recente fra i progetti e da quale progetto viene" do
      allow_n_plus_one do
        create(:release, project: rails_app, version: "v1.0.0", created_at: 3.days.ago)
        create(:release, project: flutter_app, version: "v2.4.1", created_at: 1.hour.ago)
      end

      get member_group_path(group)

      card = rollup_card("release")
      expect(card).to have_text("v2.4.1")
      expect(card).to have_text(flutter_app.name)
    end

    it "senza rilasci lo dichiara invece di mostrare un vuoto" do
      rails_app

      get member_group_path(group)

      expect(rollup_card("release")).to have_text(I18n.t("member.groups.rollup.release_none"))
    end
  end

  describe "un gruppo senza progetti" do
    it "mostra comunque la fascia, a zero, senza rompersi" do
      get member_group_path(group)

      expect(response).to have_http_status(:ok)
      expect(rollup_card("errors").text).to match(/\b0\b/)
      expect(rollup_card("tickets").text).to match(/\b0\b/)
      expect(rollup_card("uptime")).to have_text("—")
      expect(rollup_card("release")).to have_text(I18n.t("member.groups.rollup.release_none"))
    end
  end

  # Il rischio dichiarato dal ticket: il roll-up somma dati che vivono in aree diverse, quindi la
  # pagina deve dire a quale momento si riferiscono, altrimenti aggiunge un numero ambiguo.
  it "dichiara il periodo a cui si riferiscono i numeri" do
    rails_app

    get member_group_path(group)

    expect(Capybara.string(response.body).find("[data-test='group-rollup-scope']"))
      .to have_text(I18n.t("member.groups.rollup.scope_hint"))
  end
end
