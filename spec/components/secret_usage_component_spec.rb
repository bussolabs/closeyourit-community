# frozen_string_literal: true

require "rails_helper"

# CYRA-401 — La sezione «Usa questo segreto» è SEMPRE visibile nel corpo della pagina (non un tooltip):
# il comando è già compilato per il progetto e l'ambiente in vista, con le tre schede computer / build
# automatiche / server. I comandi arrivano da Secrets::UsageSnippets (unico punto).
RSpec.describe SecretUsageComponent, type: :component do
  let(:project) { double("Project", key: "CYRA") }

  describe "kind di progetto" do
    subject(:render) do
      render_inline(described_class.new(kind: :project, project: project, environment: "production",
                                        environment_codes: %w[production staging]))
    end

    it "mostra il titolo «Usa questo segreto» sempre nel corpo" do
      render
      expect(page).to have_css('[data-test="secret-usage"]')
      expect(page).to have_text(I18n.t("member.secret_usage.title"))
    end

    it "espone le tre schede computer / build automatiche / server" do
      render
      expect(page).to have_css('[data-test="secret-usage-tab-local"]')
      expect(page).to have_css('[data-test="secret-usage-tab-ci"]')
      expect(page).to have_css('[data-test="secret-usage-tab-server"]')
    end

    it "compila il comando del computer con progetto e ambiente reali" do
      render
      expect(page).to have_text("cyi run -p CYRA -e production -- <command>")
    end

    it "distingue GitHub Actions dagli altri sistemi nella scheda build (chiarimento CYRA-401)" do
      render
      expect(page).to have_css('[data-test="secret-usage-ci-github"]', text: "cyi secrets sync -p CYRA")
      expect(page).to have_css('[data-test="secret-usage-ci-generic"]', text: "export CLOSEYOURIT_TOKEN=<token>")
    end

    it "sul server mostra token + cyi run" do
      render
      expect(page).to have_css('[data-test="secret-usage-panel-server"]', text: "cyi run -p CYRA -e production")
    end

    it "abilita copia e switch delle schede (Stimulus)" do
      render
      expect(page).to have_css('[data-controller~="tabs"]')
      expect(page).to have_css('[data-controller~="clipboard"]')
      expect(page).to have_css('button[data-action~="clipboard#copy"]', minimum: 1)
    end

    it "con più ambienti ricorda come cambiare ambiente elencando i codici disponibili" do
      render
      expect(page).to have_css('[data-test="secret-usage-env-note"]', text: "staging")
    end
  end

  describe "kind personale" do
    subject(:render) { render_inline(described_class.new(kind: :personal)) }

    it "mostra `cyi personal run` e l'alternativa direnv" do
      render
      expect(page).to have_text("cyi personal run -- <command>")
      expect(page).to have_text("use_cyi_personal")
    end

    it "non mostra la variante GitHub Actions (i personali non si sincronizzano su un repo)" do
      render
      expect(page).not_to have_text("cyi secrets sync")
    end
  end

  describe "kind dell'organizzazione (shared)" do
    subject(:render) { render_inline(described_class.new(kind: :shared)) }

    it "spiega di delegare prima a un progetto e usa i segnaposto" do
      render
      expect(page).to have_css('[data-test="secret-usage-shared-note"]')
      expect(page).to have_text("cyi run -p <project> -e <environment>")
    end
  end

  describe "collapsible" do
    it "stays a plain section by default" do
      render_inline(described_class.new(kind: :personal))
      expect(page).to have_css('section[data-test="secret-usage"]')
      expect(page).to have_no_css("details")
    end

    it "folds behind its title when collapsible" do
      render_inline(described_class.new(kind: :personal, collapsible: true))
      expect(page).to have_css('details[data-test="secret-usage"] > summary', text: I18n.t("member.secret_usage.title"))
    end
  end
end
