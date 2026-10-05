# frozen_string_literal: true

require "rails_helper"

RSpec.describe AssistantHelper, type: :helper do
  let(:organization) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }

  before do
    Current.account = account
    Current.organization = organization
  end

  def bot(content, status: :complete, error_code: nil)
    build(:assistant_message, role: :assistant, status: status, content: content, error_code: error_code)
  end

  describe "#assistant_message_html" do
    it "rende un link cliccabile per un percorso del catalogo dell'utente" do
      html = helper.assistant_message_html(bot("Vai su /member/tickets per aprire."))
      expect(html).to include('href="/member/tickets"')
    end

    it "NON rende un link per un percorso inventato (anti-allucinazione): resta testo" do
      html = helper.assistant_message_html(bot("Vai su /member/inventato-xyz."))
      expect(html).not_to include('href="/member/inventato-xyz"')
      expect(html).to include("/member/inventato-xyz")
    end

    it "NON linka una funzione fuori dai permessi dell'utente (RBAC), anche se è una rotta reale" do
      member = create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
      Current.account = member
      html = helper.assistant_message_html(bot("Gestisci i membri in /member/members."))
      expect(html).not_to include('href="/member/members"')
      expect(html).to include("/member/members")
    end

    it "supporta la forma markdown [testo](/percorso) con etichetta" do
      html = helper.assistant_message_html(bot("Apri [Ticket](/member/tickets)."))
      expect(html).to include('href="/member/tickets"')
      expect(html).to include(">Ticket</a>")
    end

    it "escapa il testo del modello (nessun HTML iniettato dall'LLM)" do
      html = helper.assistant_message_html(bot("<script>alert(1)</script> ciao"))
      expect(html).not_to include("<script>")
      expect(html).to include("&lt;script&gt;")
    end

    it "spezza il testo in paragrafi" do
      html = helper.assistant_message_html(bot("Primo.\n\nSecondo."))
      expect(html.scan("<p").size).to eq(2)
    end

    # CYRA-261 — il modello risponde in markdown: prima si leggevano i trattini e gli asterischi.
    it "rende elenchi e grassetto del markdown" do
      html = helper.assistant_message_html(bot("Puoi:\n\n- aprire un **ticket**\n- vedere gli errori"))

      expect(html).to include("<li>aprire un <strong>ticket</strong></li>")
      expect(html).not_to include("- aprire un")
    end

    # Il markdown sa fare link a qualsiasi indirizzo: il filtro del catalogo vale su TUTTI gli anchor,
    # non solo sui percorsi interni. Un link esterno (allucinato, o iniettato in un contenuto che il
    # modello ha letto) non deve mai arrivare cliccabile nel pannello.
    it "smonta un link esterno lasciando solo la sua etichetta" do
      html = helper.assistant_message_html(bot("Guarda [qui](https://esca.example/login)."))

      expect(html).not_to include("href")
      expect(html).to include("qui")
    end

    it "NON linka un percorso dentro un blocco di codice (è un esempio, non un bottone)" do
      html = helper.assistant_message_html(bot("Chiama `/member/tickets` dalla riga di comando."))

      expect(html).not_to include('href="/member/tickets"')
      expect(html).to include("<code>/member/tickets</code>")
    end

    # CYRA-436 — l'errore distingue il problema momentaneo dalla domanda non capita e offre SEMPRE
    # il collegamento alle guide, così l'utente se la cava lo stesso.
    it "per un problema momentaneo mostra il messaggio 'non disponibile' col collegamento alle guide" do
      html = helper.assistant_message_html(bot(nil, status: :failed, error_code: "R502-LLM-001"))

      expect(html).to include(CGI.escapeHTML(I18n.t("member.assistant.panel.failed.unavailable")))
      expect(html).to include('href="/member/guides"')
    end

    it "per una risposta non prodotta mostra il messaggio 'domanda non capita' col collegamento alle guide" do
      html = helper.assistant_message_html(bot(nil, status: :failed, error_code: "R502-LLM-004"))

      expect(html).to include(CGI.escapeHTML(I18n.t("member.assistant.panel.failed.no_answer")))
      expect(html).not_to include(CGI.escapeHTML(I18n.t("member.assistant.panel.failed.unavailable")))
      expect(html).to include('href="/member/guides"')
    end

    # CYRA-547 — «non collegato» non è né l'uno né l'altro: non serve riformulare né riprovare fra
    # poco, perché niente cambia finché qualcuno non collega il servizio.
    it "per il servizio non collegato dice cosa manca, non «riprova tra poco»" do
      html = helper.assistant_message_html(
        bot(nil, status: :failed, error_code: Integrations::Providers::NOT_CONNECTED_CODE)
      )

      expect(html).to include(CGI.escapeHTML(I18n.t("member.assistant.panel.failed.not_connected")))
      expect(html).not_to include(CGI.escapeHTML(I18n.t("member.assistant.panel.failed.unavailable")))
    end
  end
end
