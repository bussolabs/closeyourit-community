# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::RecordVersion do
  let(:page) { create(:knowledge_page, title: "Titolo", body: "Corpo", kind: :decision) }
  let(:author) { create(:account) }

  it "congela uno snapshot del contenuto corrente della pagina" do
    version = described_class.call(page: page, author: author)

    expect(version).to be_persisted
    expect(version.page).to eq(page)
    expect(version.title).to eq("Titolo")
    expect(version.body).to eq("Corpo")
    expect(version.kind).to eq("decision")
    expect(version.organization).to eq(page.project.organization)
  end

  it "snapshotta l'autore e il suo nome" do
    version = described_class.call(page: page, author: author)
    expect(version.created_by).to eq(author)
    expect(version.author_name).to eq(author.name)
  end

  it "congela anche la sezione tecnica corrente" do
    page.update!(tech_spec: "Dettagli tecnici correnti.")
    version = described_class.call(page: page, author: author)
    expect(version.tech_spec).to eq("Dettagli tecnici correnti.")
  end

  it "accetta autore nil (author_name resta nil)" do
    version = described_class.call(page: page, author: nil)
    expect(version.created_by).to be_nil
    expect(version.author_name).to be_nil
  end

  it "numera in modo monotòno per pagina" do
    first = described_class.call(page: page, author: author)
    second = described_class.call(page: page, author: author)

    expect(first.number).to eq(1)
    expect(second.number).to eq(2)
  end
end
