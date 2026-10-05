# frozen_string_literal: true

require "rails_helper"

# CYRA-382 — il ponte errore→ticket partiva bene e finiva nel vuoto: il pulsante non diceva cosa
# avrebbe creato, e a ticket creato spariva lasciando come unica traccia una sigla in fondo alla
# colonna di destra, tre schermate più sotto.
RSpec.describe "Member::Monitoring — dall'errore al ticket (CYRA-382)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:group) { create(:error_group, project: project, title: "RuntimeError: boom", culprit: "app/models/user.rb:12") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  describe "prima di creare" do
    it "il pulsante apre un'anteprima con progetto, tipo, titolo e cosa verrà allegato" do
      get member_monitoring_error_group_path(group)

      doc = Nokogiri::HTML(response.body)
      dialog = doc.at_css("[data-test='promote-preview-dialog']")
      expect(dialog).to be_present
      expect(dialog.at_css("[data-test='promote-preview-project']").text).to include(project.name)
      expect(dialog.at_css("[data-test='promote-preview-kind']").text.strip).to be_present
      expect(dialog.at_css("[data-test='promote-preview-title']").text).to include("RuntimeError: boom")
      expect(dialog.at_css("[data-test='promote-preview-attached']").text).to include("app/models/user.rb")
      expect(dialog.at_css("[data-test='promote-preview-confirm']")).to be_present
    end

    it "il pulsante non posta più al buio" do
      get member_monitoring_error_group_path(group)

      button = Nokogiri::HTML(response.body).at_css("[data-test='promote-ticket']")
      expect(button).to be_present
      expect(button["href"]).to be_blank
    end

    # CYRA-567 Scenario 1: il chip in cima dice già «non tracciato» (CYRA-380), l'anteprima scriveva
    # ancora «su 0 persone». Quello zero finisce dentro un ticket che sopravvive alla pagina d'errore:
    # chi lo legge dopo archivia come innocuo un problema che potrebbe colpire chiunque.
    it "senza contesto utente l'anteprima dice «non tracciato», non «su 0 persone» (CYRA-567)" do
      untracked = create(:error_group, project: project, title: "UntrackedUsers", events_count: 7, users_count: 0)

      get member_monitoring_error_group_path(untracked)

      counts = Nokogiri::HTML(response.body).at_css("[data-test='promote-preview-counts']")
      expect(counts).to be_present
      expect(counts.text).to include(I18n.t("member.monitoring.users_untracked"))
      expect(counts.text).to include("7")
      expect(counts.text).not_to include(
        I18n.t("member.monitoring.promote_preview.attach_counts", events: 7, users: 0)
      )
      expect(counts.text).not_to match(/\d[\d.,]*\s+persone/i)
    end

    it "col contesto utente tracciato l'anteprima riporta il conteggio reale (CYRA-567)" do
      tracked = create(:error_group, project: project, title: "TrackedUsers", events_count: 9, users_count: 42)

      get member_monitoring_error_group_path(tracked)

      counts = Nokogiri::HTML(response.body).at_css("[data-test='promote-preview-counts']")
      expect(counts.text).to include("42")
      expect(counts.text).not_to include(I18n.t("member.monitoring.users_untracked"))
    end
  end

  describe "dopo la creazione" do
    let(:ticket) do
      create(:ticket, organization: org, project: project, title: "Boom da sistemare", assignee: owner)
    end

    before { group.update!(ticket: ticket) }

    it "in testa al dettaglio compare la barra con sigla, stato e assegnatario" do
      get member_monitoring_error_group_path(group)

      doc = Nokogiri::HTML(response.body)
      bar = doc.at_css("[data-test='error-ticket-bar']")
      expect(bar).to be_present
      expect(bar["href"]).to eq(member_ticket_path(ticket))
      expect(bar.text).to include(ticket.code)
      expect(bar.at_css("[data-test='error-ticket-bar-status']")).to be_present
      expect(bar.at_css("[data-test='error-ticket-bar-assignee']").text).to include(owner.name)
    end

    it "l'anteprima non compare più: il ticket esiste già" do
      get member_monitoring_error_group_path(group)

      expect(Nokogiri::HTML(response.body).at_css("[data-test='promote-preview-dialog']")).to be_nil
    end

    it "nell'elenco la riga mostra lo stato del ticket, non solo la sigla" do
      get member_monitoring_error_groups_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-test='error-group-ticket-#{group.id}']")).to be_present
      expect(doc.at_css("[data-test='error-group-ticket-status-#{group.id}']")).to be_present
    end
  end
end
