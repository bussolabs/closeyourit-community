# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::BackfillLinksJob do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }

  def page(title:, body: "Contenuto senza riferimenti.")
    create(:knowledge_page, organization: organization, project: project, title: title, body: body)
  end

  it "costruisce i collegamenti delle pagine scritte prima della funzionalità" do
    target = page(title: "Deploy Kamal")
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")
    Connections::PageLink.delete_all

    expect { described_class.perform_now }.to change(Connections::PageLink, :count).by(1)
    expect(source.links.reload.map(&:related)).to eq([ target ])
  end

  it "riconcilia un wikilink rimasto irrisolto perché la destinazione non esisteva ancora" do
    source = page(title: "Rollback", body: "Segue [[Deploy Kamal]].")
    expect(source.links.reload).to be_empty

    target = page(title: "Deploy Kamal")
    described_class.perform_now

    expect(source.links.reload.map(&:related)).to eq([ target ])
  end

  it "è idempotente: ripassare non duplica i collegamenti" do
    page(title: "Deploy Kamal")
    page(title: "Rollback", body: "Segue [[Deploy Kamal]].")

    described_class.perform_now
    expect { described_class.perform_now }.not_to change(Connections::PageLink, :count)
  end

  it "rimuove i collegamenti che il corpo non giustifica più" do
    target = page(title: "Deploy Kamal")
    source = page(title: "Rollback")
    create(:page_link, page: source, related: target)

    described_class.perform_now

    expect(source.links.reload).to be_empty
  end
end
