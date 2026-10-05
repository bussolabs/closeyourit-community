# frozen_string_literal: true

require "rails_helper"

# Erede di space_coverage_spec (CYRA-373). Con la sidebar unica (CYRA-521) un controller senza nodo
# non produce più una sidebar arbitraria — il menu è sempre lo stesso — ma resta muto in due punti:
# nessun gruppo si apre da solo all'atterraggio, e la briciola di pane salta il livello dell'area.
# Questa guardia impedisce che una pagina nuova nasca così, e fallisce qui invece che davanti a chi usa.
RSpec.describe Navigation::Group do
  # I controller si contano dai FILE, non da ObjectSpace: dentro una suite intera lo spazio degli
  # oggetti porta anche le classi che altri esempi hanno costruito al volo, e la guardia falliva o
  # passava a seconda di cosa era girato prima. I file sul disco sono gli stessi ovunque.
  def member_controller_paths
    radice = Rails.root.join("app/controllers")
    Dir[radice.join("member/**/*_controller.rb")].map do |file|
      Pathname(file).relative_path_from(radice).to_s.delete_suffix("_controller.rb")
    end.reject { |path| path.end_with?("/base") }.sort
  end

  it "ogni controller dell'area member appartiene a un nodo della sidebar" do
    orfani = member_controller_paths.reject { |path| described_class.for_controller(path) }

    expect(orfani).to be_empty,
                      "controller senza nodo (nessun gruppo si aprirebbe da solo, e la briciola salterebbe l'area): #{orfani.join(', ')}"
  end

  it "ogni nodo dichiarato nel registro è raggiungibile da almeno un controller" do
    # Lo specchio della guardia sopra: un nodo che non appartiene a nessuna pagina è una voce di menu
    # che non si accende mai. Le voci fisse comprese — anche la Home ha il suo controller.
    coperti = member_controller_paths.filter_map { |path| described_class.for_controller(path)&.id }.uniq
    coperti << described_class.for_controller("home")&.id

    expect(described_class.ids - coperti.compact).to be_empty
  end

  it "i gruppi di progetti stanno con i progetti, non nel monitoraggio" do
    expect(described_class.for_controller("member/groups")&.id).to eq("projects")
  end

  # CYRA-903 — the whole alert chain belongs to the Alerts area, so breadcrumb and open group agree.
  %w[member/alerting_rules member/alerting_notifications member/alerting_channels].each do |controller_path|
    it "#{controller_path} belongs to Alerts" do
      expect(described_class.for_controller(controller_path)&.id).to eq("alerts")
    end
  end

  # CYRA-581 — l'integrazione GitHub è dell'ORGANIZZAZIONE, non di un progetto: stava fra i progetti,
  # quindi la briciola diceva «Progetti» e nel menu si accendeva una voce che non porta lì.
  it "l'integrazione GitHub dell'organizzazione sta in Amministrazione, non fra i progetti" do
    expect(described_class.for_controller("member/integrations/github")&.id).to eq("settings")
  end

  it "le pagine di servizio stanno sulla Home, non su un gruppo di dominio" do
    %w[member/preferences member/guides member/changelog member/quick_add].each do |path|
      nodo = described_class.for_controller(path)&.id
      expect(nodo).to be_in(%w[home guides]), "#{path} non è fra le voci fisse in cima"
    end
  end

  it "una pagina fuori dall'area member non ha un nodo proprio" do
    expect(described_class.for_controller("valhalla/accounts")).to be_nil
  end
end
