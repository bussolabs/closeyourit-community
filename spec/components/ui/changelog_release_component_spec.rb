# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ui::ChangelogReleaseComponent, type: :component do
  let(:release) do
    Changelog::Release.new(
      version: "0.0.52",
      date: "2026-07-01",
      sections: [
        { label: "Added", items: [ "**Revisore del ticket.** Con corpo.", "Voce semplice." ] },
        { label: "Fixed", items: [ "Bugfix." ] }
      ]
    )
  end

  subject(:render) { render_inline(described_class.new(release: release)) }

  it "mostra versione e data (dato grezzo)" do
    render
    expect(page).to have_text("v0.0.52")
    expect(page).to have_text("2026-07-01")
  end

  it "traduce le label di sezione" do
    render
    expect(page).to have_text(I18n.t("shared.changelog.sections.added"))
    expect(page).to have_text(I18n.t("shared.changelog.sections.fixed"))
  end

  it "rende il grassetto **...** come <strong>" do
    render
    expect(page).to have_css("strong", text: "Revisore del ticket.")
  end

  it "non lascia gli asterischi grezzi nel testo" do
    render
    expect(page).not_to have_text("**Revisore")
  end

  it "elenca tutte le voci di ogni sezione" do
    render
    expect(page).to have_text("Voce semplice.")
    expect(page).to have_text("Bugfix.")
  end

  context "con i codici ticket scritti nella voce" do
    let(:release) do
      Changelog::Release.new(
        version: "0.0.54",
        date: "2026-07-03",
        sections: [
          { label: "Fixed", items: [
            "**Server sereni.** Ora la coda rientra da sola. (CYRA-850) [Ticket](/member/tickets)",
            "Per chi usa l'app non cambia niente (CYRA-803, CYCL-62)."
          ] }
        ]
      )
    end

    it "non mostra il codice del ticket a chi legge" do
      render
      expect(page).not_to have_text("CYRA-")
      expect(page).not_to have_text("CYCL-")
      expect(page).to have_text("Ora la coda rientra da sola.")
      expect(page).to have_text("Per chi usa l'app non cambia niente.")
      expect(page).to have_link(href: "/member/tickets")
    end
  end

  context "con link markdown interni" do
    let(:release) do
      Changelog::Release.new(
        version: "0.0.53",
        date: "2026-07-02",
        sections: [
          { label: "Added", items: [
            "Apri una segnalazione dai [Ticket](/member/tickets).",
            "Un indirizzo esterno [sito](https://esempio.test) resta testo, non un link.",
            "Un percorso protocol-relative [falso](//attacker.example) resta testo."
          ] }
        ]
      )
    end

    it "rende un link markdown interno come <a> navigabile" do
      render
      expect(page).to have_link("Ticket", href: "/member/tickets")
    end

    it "non trasforma i link esterni in <a>" do
      render
      expect(page).not_to have_css("a[href='https://esempio.test']")
      expect(page).to have_text("[sito](https://esempio.test)")
    end

    it "non trasforma i link protocol-relative in <a>" do
      render
      expect(page).not_to have_css("a[href='//attacker.example']")
      expect(page).to have_text("[falso](//attacker.example)")
    end
  end

  # CYRA-445 — la stessa area aveva più nomi nel changelog («Disponibilità», «Uptime») e nessuno
  # coincideva col menu: chi leggeva doveva indovinare che erano la stessa cosa.
  context "con nomi di area diversi da quelli del menu" do
    let(:release) do
      Changelog::Release.new(
        version: "0.0.54",
        date: "2026-07-03",
        sections: [
          { label: "Changed", items: [
            "I controlli si raggruppano. [Disponibilità](/member/monitoring/monitors)",
            "Le pagine si collegano. [Knowledge base](/member/knowledge/pages)",
            "Spiegato meglio. ([guida](/member/guides/uptime))"
          ] }
        ]
      )
    end

    it "mostra il nome che l'area ha nel menu" do
      render
      expect(page).to have_link(I18n.t("member.nav.uptime"), href: "/member/monitoring/monitors")
      expect(page).to have_link(I18n.t("member.nav.knowledge"), href: "/member/knowledge/pages")
    end

    it "non lascia il nome scritto nel file quando l'area ne ha uno nel menu" do
      render
      expect(page).not_to have_link("Disponibilità")
      expect(page).not_to have_link("Knowledge base")
    end

    it "lascia intatto il rimando alla guida, che non è un'area" do
      render
      expect(page).to have_link("guida", href: "/member/guides/uptime")
    end
  end

  # CYRA-693 — le voci oltre soglia si presentano ripiegate: lead + prima frase e «continua»;
  # le voci corte restano intere, senza piega.
  describe "piega delle voci lunghe" do
    let(:long_tail) { "Poi tutto il racconto che segue, con i dettagli di funzionamento. #{"parole " * 50}fine." }
    let(:release) do
      Changelog::Release.new(
        version: "0.0.53", date: "2026-07-02",
        sections: [ { label: "Added", items: [ "**Funzione lunga**: prima frase che riassume. #{long_tail}", "Voce corta." ] } ]
      )
    end

    it "la voce lunga mostra la prima frase e nasconde il resto dietro «continua»" do
      render
      folded = page.find("[data-test='changelog-item-folded']")
      aggregate_failures do
        expect(folded).to have_css("summary", text: /prima frase che riassume\./)
        expect(folded).to have_text(I18n.t("shared.changelog.more"))
        expect(folded).to have_text("fine.")
      end
    end

    it "la voce corta resta intera, senza piega" do
      render
      expect(page).to have_css("li", text: "Voce corta.")
      expect(page).to have_css("[data-test='changelog-item-folded']", count: 1)
    end

    it "una voce lunga senza un punto su cui tagliare resta intera: meglio lunga che mutilata" do
      senza_punti = "**Tutto attaccato**: #{"parole " * 60}senza mai chiudere la frase"
      render_inline(described_class.new(release: Changelog::Release.new(
        version: "0.0.54", date: "2026-07-03",
        sections: [ { label: "Added", items: [ senza_punti ] } ]
      )))

      expect(page).not_to have_css("[data-test='changelog-item-folded']")
    end

    it "una voce lunga senza lead in grassetto si piega comunque alla prima frase" do
      senza_lead = "Prima frase senza lead. #{"parole " * 60}fine."
      render_inline(described_class.new(release: Changelog::Release.new(
        version: "0.0.55", date: "2026-07-04",
        sections: [ { label: "Added", items: [ senza_lead ] } ]
      )))

      folded = page.find("[data-test='changelog-item-folded']")
      expect(folded).to have_css("summary", text: /Prima frase senza lead\./)
    end
  end
end
