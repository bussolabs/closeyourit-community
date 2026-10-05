# frozen_string_literal: true

require "rails_helper"

# CYRA-337 — I COLLEGAMENTI DEL PANNELLO «NOVITÀ» DEVONO PORTARE DA QUALCHE PARTE.
#
# Ogni voce del changelog cita la pagina di cui parla con un link interno (convenzione di
# CLAUDE.md §Changelog) e il pannello «Novità» lo rende cliccabile. Il link è scritto a mano in un
# file markdown: nessuno lo confronta con le rotte reali, e una pagina che nel frattempo si è
# spostata lascia dietro di sé un collegamento che finisce sul nulla. È successo alla nota di
# `0.77.5` — rimandava a `/member/uptime` mentre la pagina vive sotto `/member/monitoring/monitors`:
# l'utente veniva rassicurato su un guasto risolto e poi sbatteva contro una pagina inesistente.
#
# Questo è il guard che lo impedisce: legge il CHANGELOG vero, non un esempio.
RSpec.describe "VERIFICA collegamenti del CHANGELOG" do
  # Si interroga il router con una richiesta vera, costruita sulla configurazione dell'app: la root
  # ha un constraint che legge il cookie di sessione, e su una richiesta nuda quella lettura esplode
  # prima ancora di arrivare al routing. Si guardano le rotte candidate una per una invece di usare
  # `recognize_path`, che scarta le destinazioni di sola redirezione (`/member/workload`) perché non
  # hanno un controller da nominare: funzionano, e vanno considerate buone.
  #
  # La catch-all `/member/*path` (CYRA-462) risponde a QUALUNQUE indirizzo dell'area: atterrare lì è
  # il difetto da scoprire, non un riconoscimento riuscito.
  def raggiungibile?(path)
    env = Rails.application.env_config.merge(Rack::MockRequest.env_for(path, method: :get))
    richiesta = ActionDispatch::Request.new(env)

    Rails.application.routes.router.recognize(richiesta) do |rotta, _|
      # The redirect of old multi-word addresses is a glob too, and its constraint is not applied
      # here: a changelog link must reach the page itself, not a redirect.
      next if rotta.app.respond_to?(:constraints) && rotta.app.constraints.include?(::Routing::LegacyPaths)

      return true unless rotta.defaults[:controller] == "member/errors"
    end
    false
  end

  let(:collegamenti) do
    Rails.root.join("CHANGELOG.md").read.scan(Changelog::Areas::INTERNAL_LINK).map { |_, path| path }.uniq
  end

  # Un guard che scandaglia un file può passare per il motivo sbagliato — regex che non trova più
  # niente, riconoscimento che dice sempre sì. Questi tre casi tengono onesto il rilevatore.
  describe "il rilevatore" do
    it "riconosce come rotto l'indirizzo del ticket" do
      expect(raggiungibile?("/member/uptime")).to be(false)
    end

    it "riconosce come buona la pagina dove i controlli vivono davvero" do
      expect(raggiungibile?("/member/monitoring/monitors")).to be(true)
    end

    it "considera buona anche una destinazione che rimanda altrove" do
      expect(raggiungibile?("/member/workload")).to be(true)
    end

    it "trova i collegamenti nel file: se ne legge molti, non zero" do
      expect(collegamenti.size).to be > 30
    end
  end

  it "ogni collegamento porta a una pagina che esiste" do
    rotti = collegamenti.reject { |path| raggiungibile?(path) }

    expect(rotti).to be_empty,
      "collegamenti del CHANGELOG che non portano a nessuna pagina: #{rotti.sort.inspect}"
  end

  # Il guard sopra riconoscerebbe come buono anche l'indirizzo di un singolo record
  # (`/member/tickets/123`), che nel pannello resta però un vicolo cieco: quel record può non
  # esistere più, e per gli altri lettori non è mai esistito. La convenzione chiede una index
  # senza parametri.
  it "nessun collegamento punta a un singolo record" do
    con_id = collegamenti.select { |path| path.match?(%r{/\d+(?:/|\z)}) }

    expect(con_id).to be_empty,
      "collegamenti del CHANGELOG a un record specifico: #{con_id.sort.inspect}"
  end
end
