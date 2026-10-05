# frozen_string_literal: true

require "rails_helper"

# Le caselle del pannello "ticket simili" nel form nuovo: si spuntano mentre si scrive e il ticket
# nasce già collegato, senza pagina di confronto in mezzo. Richiede un browser reale (il pannello lo
# disegna Stimulus): gating js condiviso in spec/support/js_system.rb.
RSpec.describe "Member tickets — spunte sui simili", :js, type: :system do
  let(:org) { create(:organization) }
  let!(:project) { create(:project, organization: org) }
  let!(:status) { create(:ticket_status, organization: org, code: "open", label: "Open", color: "amber") }
  let!(:priority) { create(:ticket_priority, organization: org, code: "medium", label: "Medium", color: "amber") }
  let(:owner) do
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  around do |example|
    old_url = ENV["EMBED_BASE_URL"]
    old_key = ENV["AI_API_KEY"]
    ENV["EMBED_BASE_URL"] = "http://embed.test:7997"
    ENV["AI_API_KEY"] = "test-key"
    example.run
  ensure
    old_url ? ENV["EMBED_BASE_URL"] = old_url : ENV.delete("EMBED_BASE_URL")
    old_key ? ENV["AI_API_KEY"] = old_key : ENV.delete("AI_API_KEY")
  end

  def seeded_ticket(index, title:)
    create(:ticket, organization: org, project: project, title: title, status: status,
                    priority: priority).tap do |t|
      t.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                       embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  def stub_embed(vector)
    stub_request(:post, "http://embed.test:7997/embeddings")
      .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => vector } ] }.to_json)
  end

  it "spuntando un simile il ticket nasce collegato, senza passare dal confronto" do
    twin = seeded_ticket(0, title: "Crash al login")
    stub_embed(basis_vector(0))

    sign_in_as(owner)
    visit new_member_ticket_path(project_id: project)
    fill_test "ticket-title", with: "Il login va in crash al submit"

    expect(page).to have_css("[data-test='ticket-duplicates-panel']")
    expect(page).to have_content("100")
    check_id = "ticket-duplicates-select-#{twin.code}"
    find("[data-test='#{check_id}']").click

    # Il corpo è obbligatorio (descrizione o almeno uno scenario): senza, il salvataggio tornerebbe
    # indietro con l'errore e non si starebbe provando niente di quello che interessa qui.
    fill_test "ticket-description", with: "Premendo Entra la pagina si blocca"
    click_on_test "ticket-submit"

    # Si aspetta la scheda del ticket: senza, l'asserzione corre mentre il salvataggio è ancora in
    # volo e il ticket "non risulta" per un motivo che col codice non c'entra.
    expect(page).to have_css("[data-test='ticket-code']")
    expect(page).to have_no_css("[data-test='ticket-comparison']")
    created = Ticketing::Ticket.find_by(title: "Il login va in crash al submit")
    expect(created).to be_present
    expect(created.links.map(&:related)).to eq([ twin ])
  end

  it "una spunta tornata indietro da un errore si vede e si può togliere" do
    twin = seeded_ticket(0, title: "Crash al login")
    # Il motore è giù: il pannello non ha nulla da suggerire, e la riga può arrivare solo dai campi
    # nascosti che il salvataggio fallito ha rimandato indietro.
    stub_request(:post, "http://embed.test:7997/embeddings").to_return(status: 500, body: "{}")

    sign_in_as(owner)
    visit new_member_ticket_path(project_id: project)
    # Salvataggio che fallisce davvero come fallirebbe a mano: titolo scritto, corpo vuoto (il
    # ticket vuole una descrizione o almeno uno scenario). La spunta viaggia col form.
    fill_test "ticket-title", with: "Il login va in crash al submit"
    page.execute_script(<<~JS, twin.id)
      const form = document.querySelector("[data-test='ticket-form']")
      const box = document.createElement("input")
      box.type = "hidden"; box.name = "link_ticket_ids[]"; box.value = arguments[0]
      form.appendChild(box)
    JS
    click_on_test "ticket-submit"
    expect(page).to have_css("[data-test='ticket-form']")

    box = "[data-test='ticket-duplicates-select-#{twin.code}']"
    expect(page).to have_css(box)
    expect(find(box)).to be_checked
    expect(page).to have_content(twin.title)

    # Togliere la spunta deve togliere anche il campo nascosto da cui era arrivata: altrimenti il
    # collegamento si scriverebbe lo stesso.
    find(box).click
    expect(find(box)).not_to be_checked
    expect(page).to have_no_css("input[type='hidden'][name='link_ticket_ids[]']", visible: :all)
  end

  it "compilare altri campi non richiede di nuovo gli stessi simili" do
    seeded_ticket(0, title: "Crash al login")
    stub_embed(basis_vector(0))

    sign_in_as(owner)
    visit new_member_ticket_path(project_id: project)
    fill_test "ticket-title", with: "Il login va in crash al submit"
    expect(page).to have_css("[data-test='ticket-duplicates-panel']")

    # Il pannello ascolta l'uscita da ogni campo del form: senza una guardia, riempire gli altri
    # campi vorrebbe dire una richiesta al motore per ognuno, tutte con lo stesso testo.
    find("[data-test='ticket-weight']").click
    find("[data-test='ticket-title']").click
    expect(page).to have_css("[data-test='ticket-duplicates-panel']")

    expect(a_request(:post, "http://embed.test:7997/embeddings")).to have_been_made.once
  end

  it "cancellare il titolo e riscriverlo uguale fa tornare i suggerimenti" do
    seeded_ticket(0, title: "Crash al login")
    stub_embed(basis_vector(0))
    panel = "[data-test='ticket-duplicates-panel']"

    sign_in_as(owner)
    visit new_member_ticket_path(project_id: project)
    fill_test "ticket-title", with: "Il login va in crash al submit"
    expect(page).to have_css(panel)

    # Titolo troppo corto: il pannello sparisce. Riscrivendo LO STESSO testo deve ricomparire —
    # la guardia che evita le richieste doppie non deve trasformarsi in un pannello che non torna.
    fill_test "ticket-title", with: ""
    expect(page).to have_no_css(panel)

    fill_test "ticket-title", with: "Il login va in crash al submit"
    expect(page).to have_css(panel)
  end

  it "una riga spuntata resta anche se il servizio smette di rispondere" do
    twin = seeded_ticket(0, title: "Crash al login")
    stub_embed(basis_vector(0))

    sign_in_as(owner)
    visit new_member_ticket_path(project_id: project)
    fill_test "ticket-title", with: "Il login va in crash al submit"
    expect(page).to have_css("[data-test='ticket-duplicates-panel']")
    find("[data-test='ticket-duplicates-select-#{twin.code}']").click

    # Da qui in poi il motore è giù: i suggerimenti nuovi non arrivano più, ma la decisione già
    # presa non si butta via.
    stub_request(:post, "http://embed.test:7997/embeddings").to_return(status: 500, body: "{}")
    fill_test "ticket-title", with: "Il login va in crash al submit del form"

    expect(page).to have_css("[data-test='ticket-duplicates-select-#{twin.code}']")
    expect(find("[data-test='ticket-duplicates-select-#{twin.code}']")).to be_checked
  end
end
