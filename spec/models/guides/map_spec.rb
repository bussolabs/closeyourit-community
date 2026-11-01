# frozen_string_literal: true

require "rails_helper"

# Una pagina reale per ogni guida: è il contratto del ticket ("tutti i rimandi verificati uno per
# uno"). Serve anche da elenco di adozione: una guida nuova senza la sua riga qui fa fallire la
# spec di copertura sotto. Variabile locale, non costante: non deve finire nel namespace globale.
guide_pages = {
  "/member/monitoring/measurements" => "measurements",
  "/member/monitoring/sessions" => "session_health",
  "/member/monitoring/traces" => "traces",
  "/member/monitoring/error"    => "errors",
  "/member/monitoring/monitors"        => "uptime",
  "/member/monitoring/performance"   => "performance",
  "/member/monitoring/logs"     => "logs",
  "/member/monitoring/servers"         => "servers",
  "/member/monitoring/analytics"       => "analytics",
  "/member/monitoring/vulnerabilities" => "vulnerabilities",
  "/member/monitoring/seo"             => "seo",
  "/member/monitoring/cron"   => "crons",
  # CYRA-376 — le sessioni registrate non erano nominate da nessuna guida: chi apriva la pagina
  # leggeva quando compaiono, mai come si accendono.
  "/member/monitoring/replays"         => "replays",
  "/member/shared/secrets"             => "secrets",
  # CYRA-79 — i valori assegnati a una persona sola: la pagina sta dentro il progetto, la guida
  # spiega la parte che non si indovina (chi può darli, e che verso GitHub non escono mai).
  "/member/projects/abc-123/secrets/overrides" => "secret_overrides",
  "/member/vault"                      => "vault",
  "/member/vault/consolidations"       => "shared_values",
  "/member/knowledge"                  => "knowledge",
  "/member/knowledge/pages"            => "knowledge",
  "/member/knowledge/books"            => "knowledge",
  "/member/knowledge/reviews"          => "knowledge_review",
  "/member/tickets"                    => "tickets",
  "/member/helpdesk"                   => "helpdesk",
  "/member/projects/abc-123/helpdesk"  => "helpdesk",
  "/member/datasets"                   => "datasets",
  # CYRA-501 — le macchine che lavorano i ticket e la versione delle competenze che eseguono:
  # erano le due funzioni su cui il prodotto si gioca il valore, senza una riga di spiegazione.
  "/member/agents"                     => "agents",
  "/member/skills"               => "skill_bundles",
  # CYRA-593 — l'elenco di tutte le lavorazioni in volo: dalla pagina si arriva alla guida che
  # spiega la differenza fra ciò che aspetta una persona e ciò che va avanti da solo.
  "/member/product/matrix"             => "feature_matrix",
  "/member/home/approvals"             => "approvals",
  "/member/organization/guidance"      => "guidance",
  "/member/roles"                      => "permissions",
  # CYRA-745 — dal registro di «chi ha fatto cosa» si arriva alla guida che dice cosa ci si trova.
  "/member/activity"                   => "activity",
  # CYRA-160 — il riepilogo periodico dei dati si accende dalle preferenze delle notifiche: da lì
  # si arriva alla guida che dice cosa contiene e quando arriva.
  "/member/preferences/notifications"  => "reports",
  # CYRA-441 — piattaforme e ambienti aprivano su una tabella senza una parola su cosa fossero: la
  # guida dei contenitori spiega dove vivono le cose, e da lì ci si arriva.
  "/member/platforms"                  => "structure",
  "/member/environments"               => "structure",
  # CYRA-545 — i servizi esterni collegati con la chiave dell'organizzazione: la pagina si legge in
  # fretta, la guida spiega cos'è una chiave, chi ne paga il consumo e cosa si spegne togliendola.
  "/member/integrations"               => "integrations",
  # CYRA-879 — the move pages of a project or group open the guide on moving between organizations.
  "/member/projects/abc-123/move/new"  => "project_moves"
}.freeze

RSpec.describe Guides::Map do
  describe ".slug_for" do
    guide_pages.each do |path, slug|
      it "manda #{path} alla guida #{slug}" do
        expect(described_class.slug_for(path)).to eq(slug)
      end
    end

    it "riconosce anche le pagine figlie di una funzione" do
      expect(described_class.slug_for("/member/monitoring/monitors/abc-123")).to eq("uptime")
    end

    it "sulla revisione della conoscenza sceglie la guida della revisione, non quella della knowledge" do
      expect(described_class.slug_for("/member/knowledge/reviews")).to eq("knowledge_review")
    end

    it "riconosce la guidance dentro un progetto, nonostante l'id nel mezzo" do
      expect(described_class.slug_for("/member/projects/abc-123/guidance")).to eq("guidance")
    end

    # CYRA-441 — la guida dei contenitori copre anche la pagina dell'organizzazione, ma le istruzioni
    # per gli assistenti restano sulla loro: la regola più specifica vince, come sempre qui.
    it "l'organizzazione porta ai contenitori, la sua guidance resta sulla propria guida" do
      expect(described_class.slug_for("/member/organization/edit")).to eq("structure")
      expect(described_class.slug_for("/member/organization/guidance")).to eq("guidance")
    end

    it "sends the renamed single-word pages to their guides" do
      expect(described_class.slug_for("/member/monitoring/groups")).to eq("uptime")
      expect(described_class.slug_for("/member/monitoring/tokens")).to eq("servers")
      expect(described_class.slug_for("/member/monitoring/sites/abc-123")).to eq("seo")
      expect(described_class.slug_for("/member/personal/files")).to eq("secrets")
    end

    it "ignora la query string" do
      expect(described_class.slug_for("/member/tickets?status=open")).to eq("tickets")
    end

    it "restituisce nil per una pagina senza guida" do
      expect(described_class.slug_for("/member/preferences")).to be_nil
    end

    it "restituisce nil fuori dall'area member" do
      expect(described_class.slug_for("/valhalla/accounts")).to be_nil
    end

    it "restituisce nil sulle guide stesse" do
      expect(described_class.slug_for("/member/guides/uptime")).to be_nil
    end

    it "restituisce nil per un path assente o vuoto" do
      expect(described_class.slug_for(nil)).to be_nil
      expect(described_class.slug_for("")).to be_nil
    end
  end

  describe ".path_for" do
    it "restituisce il path della guida della pagina corrente" do
      expect(described_class.path_for("/member/monitoring/logs")).to eq("/member/guides/logs")
    end

    it "usa il trattino nello slug composto, come la rotta" do
      expect(described_class.path_for("/member/knowledge/reviews")).to eq("/member/guides/knowledge-review")
    end

    it "restituisce nil quando la pagina non ha guida" do
      expect(described_class.path_for("/member/preferences")).to be_nil
    end

    # CYRA-432 — le raccolte non hanno una guida propria: mandarle in cima alla guida generale
    # significa farle cercare. La regola porta alla SEZIONE che le spiega, dentro la stessa guida.
    it "porta alla sezione della guida generale quando la schermata non ha una guida sua" do
      expect(described_class.path_for("/member/knowledge/books")).to eq("/member/guides/knowledge#books")
    end

    it "non aggiunge sezioni alle schermate che aprono la guida dall'inizio" do
      expect(described_class.path_for("/member/knowledge/pages")).to eq("/member/guides/knowledge")
      expect(described_class.path_for("/member/knowledge")).to eq("/member/guides/knowledge")
    end
  end

  describe "copertura delle guide" do
    let(:guide_slugs) { Member::GuidesController.instance_methods(false).map(&:to_s) - %w[index] }

    # CYRA-435 — le guide d'insieme non spiegano una pagina: si aprono dall'indice, e sono
    # dichiarate in STANDALONE. Tutte le altre devono avere la loro pagina sorgente.
    it "ogni guida esistente è raggiungibile da una pagina, o è dichiarata d'insieme" do
      expect(described_class.slugs + described_class::STANDALONE).to match_array(guide_slugs)
    end

    it "ogni guida esistente ha una pagina d'esempio verificata qui" do
      expect(guide_pages.values.uniq + described_class::STANDALONE).to match_array(guide_slugs)
    end

    it "le guide d'insieme hanno una rotta valida" do
      described_class::STANDALONE.each do |slug|
        expect(Rails.application.routes.url_helpers).to respond_to(:"member_guides_#{slug}_path")
      end
    end

    it "ogni guida mappata ha una rotta valida" do
      described_class.slugs.each do |slug|
        expect(Rails.application.routes.url_helpers).to respond_to(:"member_guides_#{slug}_path")
      end
    end

    it "ogni pagina d'esempio è instradabile dall'applicazione" do
      guide_pages.each_key do |path|
        expect { Rails.application.routes.recognize_path(path) }.not_to raise_error
      end
    end
  end
end
