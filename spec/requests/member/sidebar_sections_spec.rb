# frozen_string_literal: true

require "rails_helper"

# CYRA-521 — la sidebar è una sola e non cambia mai forma. Prima era verticalizzata in nove aree e
# seguiva la pagina (CYRA-139, "Model B"): partendo dalla Home e premendo Ticket o Idee — che
# appartenevano all'area Applicativi — il menu si riscriveva sotto le dita, e la voce appena premuta
# finiva in un altro punto dell'elenco.
#
# Resta la regola CYRA-29 "niente header orfano", ora a due livelli: un gruppo con tutte le voci
# nascoste non compare, e una macro-sezione senza gruppi nemmeno.
RSpec.describe "Member sidebar — un menu solo, con gruppi", type: :request do
  let(:org) { create(:organization) }

  def account_with(role)
    account = create(:account)
    create(:membership, account: account, organization: org, role: role)
    account
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # La firma della sidebar: cosa contiene, nell'ordine in cui compare. Due pagine con la stessa firma
  # hanno lo stesso menu — che è esattamente ciò che il ticket chiede.
  def firma_sidebar
    # The section divider repeats between sections by design: it is a separator, not an entry.
    Nokogiri::HTML(response.body).css("#member-sidebar [data-test^='member-nav-']:not([data-test='member-nav-section-divider'])")
                                 .map { |nodo| nodo["data-test"] }
  end

  # `open` è un attributo booleano: su un <details> aperto vale la stringa vuota, quindi si controlla
  # che ci sia, non che valga qualcosa.
  def gruppo_aperto?(id)
    Nokogiri::HTML(response.body).at_css("[data-test='member-nav-toggle-#{id}'][aria-expanded='true']").present?
  end

  it "il menu è identico sulla pagina iniziale e sui ticket" do
    sign_in(account_with(:owner))

    get root_path
    dalla_home = firma_sidebar

    get member_tickets_path

    expect(firma_sidebar).to eq(dalla_home)
  end

  it "il menu è identico anche sulle idee e in fondo a una verticale" do
    sign_in(account_with(:owner))

    get root_path
    dalla_home = firma_sidebar

    get member_ideas_path
    expect(firma_sidebar).to eq(dalla_home)

    get member_monitoring_servers_path
    expect(firma_sidebar).to eq(dalla_home)
  end

  it "shows the pinned entries and Guides on every page, even deep in an area" do
    sign_in(account_with(:owner))

    get member_monitoring_servers_path

    %w[member-nav-home member-nav-my-work member-nav-approvals member-nav-conversations
       member-nav-home-todos member-nav-guides].each do |voce|
      expect(response.body).to include(%(data-test="#{voce}"))
    end
  end

  it "mostra le tre macro-sezioni coi loro gruppi" do
    sign_in(account_with(:owner))
    get root_path

    %w[member-nav-section-work member-nav-section-system member-nav-section-account
       member-nav-group-product member-nav-group-observability
       member-nav-group-vault].each do |tag|
      expect(response.body).to include(%(data-test="#{tag}"))
    end
  end

  it "il gruppo che contiene la pagina aperta parte aperto, gli altri restano chiusi" do
    sign_in(account_with(:owner))

    get member_monitoring_error_groups_path

    expect(gruppo_aperto?("observability")).to be(true)
    expect(gruppo_aperto?("vault")).to be(false)
  end

  it "sulla pagina iniziale nessun gruppo parte aperto: la Home non sta in un gruppo" do
    sign_in(account_with(:owner))

    get root_path

    aperti = Nokogiri::HTML(response.body).css("#member-sidebar [data-test^='member-nav-toggle-'][aria-expanded='true']")

    expect(aperti).to be_empty
  end

  it "nessuna voce compare in due punti diversi del menu" do
    sign_in(account_with(:owner))
    get root_path

    voci = firma_sidebar

    expect(voci).to eq(voci.uniq)
  end

  it "il selettore d'area in alto non esiste più" do
    sign_in(account_with(:owner))
    get root_path

    expect(response.body).not_to include('data-test="member-space-switcher"')
  end

  it "non esistono macro-sezioni senza gruppi sotto" do
    sign_in(account_with(:member))
    get root_path

    Nokogiri::HTML(response.body).css("[data-test^='member-nav-section-']").each do |header|
      expect(header.parent.css("a, details")).not_to be_empty,
                                                     "la sezione #{header.text} non ha nessun gruppo sotto"
    end
  end
end
